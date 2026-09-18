import Foundation
import TransferCore

private var retainedRuntime: TransferCenterRuntime?
private var retainedProbe: ProgressProbe?
private var retainedBridge: DynamicLakeBridge?
private var signalSources: [DispatchSourceSignal] = []

private var supportsPresentSneakPeek: Bool {
    Set((ProcessInfo.processInfo.environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "")
        .split(separator: ",").map(String.init)).contains("presentSneakPeek")
}

private func installSignalHandlers(_ cleanup: @escaping () -> Void) {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { cleanup(); exit(0) }
        source.resume()
        signalSources.append(source)
    }
}

private func printVolumes(_ volumes: [Volume]) {
    for volume in volumes {
        print("\(volume.name)\t\(volume.mountURL.path)\t\(volume.kind.rawValue)\tinternal=\(String(describing: volume.isInternal))\tlocal=\(String(describing: volume.isLocal))\tremovable=\(String(describing: volume.isRemovable))\tejectable=\(String(describing: volume.isEjectable))")
    }
}

@main
private enum Main {
    static func main() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        Logger.shared.isDebugEnabled = arguments.contains("--debug")

        let mockTransfer = Transfer(
            id: "mock-transfer",
            kind: .copying,
            state: .active,
            destinationVolumeID: "mock-volume",
            volumeName: "Development SSD",
            displayName: "Copying to Development SSD",
            currentFileName: "Video Project.fcpbundle",
            fractionCompleted: 0.42,
            bytesCompleted: 29_400_000_000,
            bytesTotal: 70_000_000_000,
            filesCompleted: 182,
            filesTotal: 931,
            bytesPerSecond: 584_000_000,
            estimatedSecondsRemaining: 96,
            startedAt: Date().addingTimeInterval(-28),
            updatedAt: Date(),
            isCancellable: true,
            provider: .foundationProgress,
            confidence: .exact
        )

        if arguments.contains("--demo-json") {
            for payload in [
                DynamicLakeRenderer.activePayload(transfer: mockTransfer, activeCount: 1, command: "create"),
                DynamicLakeRenderer.terminalPayload(transfer: {
                    var value = mockTransfer
                    value.state = .completed
                    value.completedAt = Date()
                    value.fractionCompleted = 1
                    return value
                }(), command: "update", canEject: true),
            ] {
                let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }

        if arguments.contains("--mock-transfer") {
            do {
                let bridge = try DynamicLakeBridge()
                retainedBridge = bridge
                try bridge.connect()
                try bridge.send(DynamicLakeRenderer.activePayload(transfer: mockTransfer, activeCount: 1, command: "create"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    var finished = mockTransfer
                    finished.state = .completed
                    finished.fractionCompleted = 1
                    finished.completedAt = Date()
                    try? bridge.send(DynamicLakeRenderer.terminalPayload(
                        transfer: finished,
                        command: "update",
                        canEject: false,
                        supportsPresentSneakPeek: supportsPresentSneakPeek
                    ))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    try? bridge.send(DynamicLakeRenderer.dismissPayload(activityID: DynamicLakeRenderer.activityID))
                }
                installSignalHandlers { bridge.close() }
                RunLoop.main.run()
            } catch {
                fputs("Transfer Center mock: \(error.localizedDescription)\n", stderr)
                exit(64)
            }
            return
        }

        if arguments.contains("--probe-progress") {
            let probe = ProgressProbe()
            retainedProbe = probe
            probe.start()
            installSignalHandlers { probe.stop() }
            RunLoop.main.run()
            return
        }

        if arguments.contains("--list-volumes") || arguments.contains("--diagnostics") {
            let monitor = VolumeMonitor()
            monitor.start()
            printVolumes(monitor.volumes)
            if arguments.contains("--diagnostics") {
                print("DynamicLake socket: \(ProcessInfo.processInfo.environment["DYNAMICLAKE_JSON_SOCKET"] == nil ? "missing" : "present")")
                print("Finder Accessibility: \(FinderAccessibilityProvider.isPermissionGranted ? "granted" : "not granted")")
                print("Debug log: \(Logger.shared.logURL.path)")
                print("External volumes: \(monitor.volumes.filter(\.isRelevantExternal).count)")
            }
            monitor.stop()
            return
        }

        do {
            var settings = PluginSettings.load()
            if arguments.contains("--enable-finder-accessibility") { settings.finderAccessibilityFallback = true }
            let bridge = try DynamicLakeBridge()
            let runtime = TransferCenterRuntime(bridge: bridge, settings: settings)
            retainedRuntime = runtime
            try runtime.start()
            installSignalHandlers { runtime.stop() }
            RunLoop.main.run()
        } catch {
            fputs("Transfer Center: \(error.localizedDescription)\n", stderr)
            exit(64)
        }
    }
}
