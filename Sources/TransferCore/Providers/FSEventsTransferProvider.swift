import CoreServices
import Foundation

public final class FSEventsTransferProvider: TransferProvider {
    public let name = "FSEvents activity fallback"
    public weak var delegate: TransferProviderDelegate?

    private struct Activity {
        var transfer: Transfer
        var settleWorkItem: DispatchWorkItem?
    }

    private var streams: [String: FSEventStreamRef] = [:]
    private var activities: [String: Activity] = [:]
    private var volumesByID: [String: Volume] = [:]
    private let queue = DispatchQueue(label: "com.rafaelreverberi.transfer-center.fsevents")

    public init() {}

    public func start(volumes: [Volume]) { update(volumes: volumes) }

    public func update(volumes: [Volume]) {
        queue.async { [weak self] in self?.replaceVolumes(volumes) }
    }

    public func stop() {
        queue.sync {
            for stream in streams.values {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            streams.removeAll()
            for activity in activities.values { activity.settleWorkItem?.cancel() }
            activities.removeAll()
        }
    }

    private func replaceVolumes(_ volumes: [Volume]) {
        let relevant = Dictionary(uniqueKeysWithValues: volumes.filter(\.isRelevantExternal).map { ($0.id, $0) })
        for (id, stream) in streams where relevant[id] == nil {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streams.removeValue(forKey: id)
        }
        volumesByID = relevant
        for volume in relevant.values where streams[volume.id] == nil { createStream(for: volume) }
    }

    private func createStream(for volume: Volume) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let provider = Unmanaged<FSEventsTransferProvider>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: CFArray.self) as NSArray
            for index in 0..<count {
                guard let path = pathArray[Int(index)] as? String else { continue }
                provider.handle(path: path, flags: flags[Int(index)])
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [volume.mountURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            Logger.shared.warning("Unable to create FSEvents stream for \(volume.name)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        streams[volume.id] = stream
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        let meaningful = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemInodeMetaMod |
            kFSEventStreamEventFlagItemXattrMod
        ) != 0
        guard meaningful else { return }
        guard let volume = volumesByID.values
            .filter({ path.hasPrefix($0.mountURL.path) })
            .max(by: { $0.mountURL.path.count < $1.mountURL.path.count }) else { return }

        let id = "fsevents-\(volume.id)"
        let now = Date()
        var activity = activities[id] ?? Activity(
            transfer: Transfer(
                id: id,
                kind: .fileActivity,
                state: .indeterminate,
                destinationURL: volume.mountURL,
                destinationVolumeID: volume.id,
                volumeName: volume.name,
                displayName: "Transferring to \(volume.name)",
                startedAt: now,
                updatedAt: now,
                provider: .fsevents,
                confidence: .activity
            ),
            settleWorkItem: nil
        )
        activity.transfer.updatedAt = now
        activity.transfer.currentFileName = URL(fileURLWithPath: path).lastPathComponent
        activity.settleWorkItem?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.settled(id: id) }
        activity.settleWorkItem = settle
        activities[id] = activity
        delegate?.transferProvider(self, emitted: .updated(activity.transfer))
        queue.asyncAfter(deadline: .now() + 1.5, execute: settle)
    }

    private func settled(id: String) {
        guard activities.removeValue(forKey: id) != nil else { return }
        delegate?.transferProvider(self, emitted: .removed(id: id, finalState: .completed))
    }

    deinit { stop() }
}
