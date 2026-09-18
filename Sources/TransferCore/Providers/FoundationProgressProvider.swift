import Foundation

public final class FoundationProgressProvider: TransferProvider, @unchecked Sendable {
    public let name = "Foundation Progress"
    public weak var delegate: TransferProviderDelegate?

    private struct ObservedProgress {
        let progress: Progress
        let volume: Volume
        let startedAt: Date
        let transferID: String
        var lifecycle = ProgressLifecycleGate()
    }

    private var subscribers: [String: Any] = [:]
    private var observed: [ObjectIdentifier: ObservedProgress] = [:]
    private var timer: DispatchSourceTimer?
    private var currentVolumes: [Volume] = []

    public init() {}

    public func start(volumes: [Volume]) {
        update(volumes: volumes)
    }

    public func update(volumes: [Volume]) {
        dispatchPrecondition(condition: .onQueue(.main))
        currentVolumes = volumes
        let relevant = Dictionary(uniqueKeysWithValues: volumes.filter(\.isRelevantExternal).map { ($0.id, $0) })

        for (id, token) in subscribers where relevant[id] == nil {
            Progress.removeSubscriber(token)
            subscribers.removeValue(forKey: id)
        }

        for volume in relevant.values where subscribers[volume.id] == nil {
            let token = Progress.addSubscriber(forFileURL: volume.mountURL) { [weak self] progress in
                guard let self else { return nil }
                let key = ObjectIdentifier(progress)
                DispatchQueue.main.async {
                    self.observed[key] = ObservedProgress(
                        progress: progress,
                        volume: volume,
                        startedAt: Date(),
                        transferID: "progress-\(UUID().uuidString)"
                    )
                    self.ensureTimer()
                    self.sample(key: key)
                }
                return { [weak self] in
                    DispatchQueue.main.async {
                        self?.finish(key: key)
                    }
                }
            }
            subscribers[volume.id] = token
            Logger.shared.debug("Subscribed to file progress for volume \(volume.name)")
        }
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        for token in subscribers.values { Progress.removeSubscriber(token) }
        subscribers.removeAll()
        observed.removeAll()
        timer?.cancel()
        timer = nil
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        for key in Array(observed.keys) { sample(key: key) }
        if observed.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    private func finish(key: ObjectIdentifier) {
        guard var entry = observed.removeValue(forKey: key) else { return }
        let progress = entry.progress
        let state: TransferState = progress.isCancelled ? .cancelled : (progress.isFinished ? .completed : .failed)
        guard entry.lifecycle.shouldEmit(state) else {
            Logger.shared.debug("Ignored terminal-only file progress for volume \(entry.volume.name)")
            return
        }
        delegate?.transferProvider(self, emitted: .removed(id: entry.transferID, finalState: state))
    }

    private func sample(key: ObjectIdentifier) {
        guard var entry = observed[key] else { return }
        let state = transferState(entry.progress)
        let shouldEmit = entry.lifecycle.shouldEmit(state)
        observed[key] = entry
        guard shouldEmit else { return }
        emit(entry.progress, volume: entry.volume, startedAt: entry.startedAt, transferID: entry.transferID, state: state)
    }

    private func transferState(_ progress: Progress) -> TransferState {
        if progress.isCancelled { return .cancelled }
        if progress.isFinished { return .completed }
        if progress.totalUnitCount <= 0 || progress.isIndeterminate { return .indeterminate }
        return .active
    }

    private func emit(_ progress: Progress, volume: Volume, startedAt: Date, transferID: String, state: TransferState) {
        let fileURL = progress.fileURL
        let matchedVolume = currentVolumes
            .filter { fileURL?.standardizedFileURL.path.hasPrefix($0.mountURL.standardizedFileURL.path) == true }
            .max { $0.mountURL.path.count < $1.mountURL.path.count } ?? volume
        let throughput = progress.throughput.map(Int64.init)
        let likelyByteUnits = throughput != nil
        let fraction = progress.isIndeterminate ? nil : clamped(progress.fractionCompleted)
        let transfer = Transfer(
            id: transferID,
            kind: transferKind(progress.fileOperationKind),
            state: state,
            destinationURL: fileURL,
            destinationVolumeID: matchedVolume.id,
            volumeName: matchedVolume.name,
            displayName: progress.localizedDescription.isEmpty ? "File transfer" : progress.localizedDescription,
            currentFileName: fileURL?.lastPathComponent,
            fractionCompleted: fraction,
            bytesCompleted: likelyByteUnits ? max(0, progress.completedUnitCount) : nil,
            bytesTotal: likelyByteUnits && progress.totalUnitCount > 0 ? progress.totalUnitCount : nil,
            filesCompleted: progress.fileCompletedCount,
            filesTotal: progress.fileTotalCount,
            bytesPerSecond: throughput,
            estimatedSecondsRemaining: progress.estimatedTimeRemaining,
            startedAt: startedAt,
            updatedAt: Date(),
            completedAt: state == .completed ? Date() : nil,
            isCancellable: progress.isCancellable,
            isPausable: progress.isPausable,
            provider: .foundationProgress,
            confidence: .exact
        )
        delegate?.transferProvider(self, emitted: .updated(transfer))
    }

    private func transferKind(_ kind: Progress.FileOperationKind?) -> TransferKind {
        switch kind {
        case .copying, .duplicating: return .copying
        case .downloading: return .downloading
        case .receiving: return .receiving
        case .uploading: return .uploading
        default: return .copying
        }
    }

    private func clamped(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    deinit {
        if Thread.isMainThread { stop() }
    }
}

struct ProgressLifecycleGate {
    private(set) var hasSeenNonterminal = false
    private(set) var hasEmittedTerminal = false

    mutating func shouldEmit(_ state: TransferState) -> Bool {
        if state.isActive {
            hasSeenNonterminal = true
            return true
        }
        guard hasSeenNonterminal, !hasEmittedTerminal else { return false }
        hasEmittedTerminal = true
        return true
    }
}
