import AppKit
import Foundation

public final class VolumeMonitor: NSObject {
    public typealias VolumesChanged = ([Volume]) -> Void
    public typealias VolumeEvent = (Volume) -> Void

    public var onVolumesChanged: VolumesChanged?
    public var onMounted: VolumeEvent?
    public var onWillUnmount: VolumeEvent?
    public var onUnmounted: VolumeEvent?

    public private(set) var volumes: [Volume] = []
    private var started = false

    public func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didMount(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(willUnmount(_:)), name: NSWorkspace.willUnmountNotification, object: nil)
        center.addObserver(self, selector: #selector(didUnmount(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        refresh()
    }

    public func stop() {
        guard started else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        started = false
    }

    public func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(VolumeMetadataReader.keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        volumes = urls.compactMap(VolumeMetadataReader.snapshot).map(VolumeClassifier.makeVolume)
        onVolumesChanged?(volumes)
    }

    @objc private func didMount(_ notification: Notification) {
        guard let volume = volume(from: notification) else { refresh(); return }
        refresh()
        onMounted?(volume)
    }

    @objc private func willUnmount(_ notification: Notification) {
        guard let volume = volume(from: notification) else { return }
        onWillUnmount?(volume)
    }

    @objc private func didUnmount(_ notification: Notification) {
        let removed = volume(from: notification)
        refresh()
        if let removed { onUnmounted?(removed) }
    }

    private func volume(from notification: Notification) -> Volume? {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let snapshot = VolumeMetadataReader.snapshot(for: url) else { return nil }
        return VolumeClassifier.makeVolume(from: snapshot)
    }

    deinit { stop() }
}
