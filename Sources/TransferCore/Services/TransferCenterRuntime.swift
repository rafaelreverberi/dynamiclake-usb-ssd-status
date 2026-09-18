import Foundation

public final class TransferCenterRuntime {
    private let bridge: DynamicLakeBridge
    private let renderer: DynamicLakeRenderer
    private let coordinator = TransferCoordinator()
    private let monitor = VolumeMonitor()
    private let foundationProvider = FoundationProgressProvider()
    private let fseventsProvider = FSEventsTransferProvider()
    private let finderProvider: FinderAccessibilityProvider
    private let settings: PluginSettings
    private lazy var ejectService = EjectService(isTransferActive: { [weak coordinator] id in
        coordinator?.hasActiveTransfer(for: id) ?? true
    })
    private var volumes: [String: Volume] = [:]

    public init(bridge: DynamicLakeBridge, settings: PluginSettings) {
        self.bridge = bridge
        self.renderer = DynamicLakeRenderer(bridge: bridge)
        self.settings = settings
        self.finderProvider = FinderAccessibilityProvider(enabled: settings.finderAccessibilityFallback)
    }

    public func start() throws {
        try bridge.connect()
        foundationProvider.delegate = coordinator
        fseventsProvider.delegate = coordinator
        finderProvider.delegate = coordinator
        coordinator.onChange = { [weak renderer] transfers in renderer?.render(transfers) }
        bridge.onAction = { [weak self] actionID, _ in self?.handleAction(actionID) }
        bridge.onDisconnect = { Logger.shared.warning("DynamicLake connection ended; waiting for the host to restart the plugin") }

        monitor.onVolumesChanged = { [weak self] volumes in self?.replaceVolumes(volumes) }
        monitor.onMounted = { [weak self] volume in
            guard let self, volume.isRelevantExternal, self.settings.showDriveConnected else { return }
            self.renderer.showMounted(volume)
        }
        monitor.onUnmounted = { [weak self] volume in self?.coordinator.handleVolumeDisconnected(volume.id) }
        monitor.start()
        foundationProvider.start(volumes: monitor.volumes)
        fseventsProvider.start(volumes: monitor.volumes)
        finderProvider.start(volumes: monitor.volumes)
        Logger.shared.info("Transfer Center started with \(monitor.volumes.filter(\.isRelevantExternal).count) external volume(s)")
    }

    public func stop() {
        foundationProvider.stop()
        fseventsProvider.stop()
        finderProvider.stop()
        monitor.stop()
        bridge.close()
    }

    private func replaceVolumes(_ values: [Volume]) {
        volumes = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        foundationProvider.update(volumes: values)
        fseventsProvider.update(volumes: values)
        finderProvider.update(volumes: values)
    }

    private func handleAction(_ actionID: String) {
        guard actionID == "eject", let id = renderer.presentedEjectVolumeID, let volume = volumes[id] else { return }
        ejectService.eject(volume) { [weak renderer] result in renderer?.showEjectResult(result, volumeName: volume.name) }
    }

    deinit { stop() }
}
