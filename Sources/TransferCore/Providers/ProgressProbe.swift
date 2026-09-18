import Foundation

public final class ProgressProbe: @unchecked Sendable {
    private struct Entry {
        let progress: Progress
        let volume: Volume
    }

    private let monitor = VolumeMonitor()
    private var subscribers: [String: Any] = [:]
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: DispatchSourceTimer?

    public init() {}

    public func start() {
        monitor.onVolumesChanged = { [weak self] in self?.replaceVolumes($0) }
        monitor.onMounted = { volume in Swift.print("[volume-mounted] \(Self.describe(volume))") }
        monitor.onWillUnmount = { volume in Swift.print("[volume-will-unmount] \(volume.name)") }
        monitor.onUnmounted = { volume in Swift.print("[volume-unmounted] \(volume.name)") }
        monitor.start()
        if monitor.volumes.filter(\.isRelevantExternal).isEmpty {
            Swift.print("No external/removable volume is mounted. The probe is waiting for one.")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.printUpdates() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        for token in subscribers.values { Progress.removeSubscriber(token) }
        subscribers.removeAll()
        entries.removeAll()
        monitor.stop()
    }

    private func replaceVolumes(_ volumes: [Volume]) {
        let relevant = Dictionary(uniqueKeysWithValues: volumes.filter(\.isRelevantExternal).map { ($0.id, $0) })
        for (id, token) in subscribers where relevant[id] == nil {
            Progress.removeSubscriber(token)
            subscribers.removeValue(forKey: id)
        }
        for volume in relevant.values where subscribers[volume.id] == nil {
            Swift.print("[subscribe] \(Self.describe(volume))")
            subscribers[volume.id] = Progress.addSubscriber(forFileURL: volume.mountURL) { [weak self] progress in
                let id = ObjectIdentifier(progress)
                DispatchQueue.main.async {
                    self?.entries[id] = Entry(progress: progress, volume: volume)
                    Swift.print("[progress-published] id=\(id.hashValue) old=\(progress.isOld)")
                    self?.printProgress(progress, volume: volume)
                }
                return { [weak self] in
                    DispatchQueue.main.async {
                        if let entry = self?.entries.removeValue(forKey: id) {
                            Swift.print("[progress-unpublished] id=\(id.hashValue)")
                            self?.printProgress(entry.progress, volume: entry.volume)
                        }
                    }
                }
            }
        }
    }

    private func printUpdates() {
        for entry in entries.values { printProgress(entry.progress, volume: entry.volume) }
    }

    private func printProgress(_ progress: Progress, volume: Volume) {
        let fields = [
            "id=\(ObjectIdentifier(progress).hashValue)",
            "volume=\(volume.name)",
            "kind=\(progress.fileOperationKind?.rawValue ?? "unknown")",
            "url=\(progress.fileURL?.path ?? "unknown")",
            "fraction=\(progress.isIndeterminate ? "indeterminate" : String(format: "%.4f", progress.fractionCompleted))",
            "units=\(progress.completedUnitCount)/\(progress.totalUnitCount)",
            "files=\(optionalPair(progress.fileCompletedCount, progress.fileTotalCount))",
            "throughput=\(progress.throughput.map(String.init) ?? "unknown")",
            "eta=\(progress.estimatedTimeRemaining.map { String(format: "%.1f", $0) } ?? "unknown")",
            "cancellable=\(progress.isCancellable)",
            "pausable=\(progress.isPausable)",
            "finished=\(progress.isFinished)",
            "cancelled=\(progress.isCancelled)",
            "description=\(singleLine(progress.localizedDescription))",
            "additional=\(singleLine(progress.localizedAdditionalDescription))",
        ]
        Swift.print("[progress] " + fields.joined(separator: " "))
    }

    private func optionalPair(_ first: Int?, _ second: Int?) -> String {
        guard let first, let second else { return "unknown" }
        return "\(first)/\(second)"
    }

    private func singleLine(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\n", with: " ").prefix(240))\""
    }

    private static func describe(_ volume: Volume) -> String {
        "name=\(volume.name) mount=\(volume.mountURL.path) kind=\(volume.kind.rawValue) internal=\(String(describing: volume.isInternal)) local=\(String(describing: volume.isLocal)) removable=\(String(describing: volume.isRemovable)) ejectable=\(String(describing: volume.isEjectable)) readOnly=\(String(describing: volume.isReadOnly))"
    }

    deinit { stop() }
}
