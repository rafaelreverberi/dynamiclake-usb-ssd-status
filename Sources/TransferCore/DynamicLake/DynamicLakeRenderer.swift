import Foundation

public final class DynamicLakeRenderer {
    public static let activityID = "transfer-center.active"
    private let bridge: DynamicLakeBridge
    private let minimumVisibleDelay: TimeInterval = 0.75
    private let minimumUpdateInterval: TimeInterval = 0.25
    private var firstSeen: [String: Date] = [:]
    private var presentedTransferIDs: Set<String> = []
    private var lastPayloadSignature: String?
    private var lastSentAt = Date.distantPast
    private var published = false
    private var pendingWorkItem: DispatchWorkItem?
    private let supportsPresentSneakPeek: Bool
    public private(set) var presentedEjectVolumeID: String?

    public init(
        bridge: DynamicLakeBridge,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.bridge = bridge
        let features = Set((environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init))
        self.supportsPresentSneakPeek = features.contains("presentSneakPeek")
    }

    public func render(_ transfers: [Transfer]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let active = transfers.filter(\.state.isActive)
        presentedTransferIDs.formIntersection(Set(transfers.map(\.id)))
        for transfer in active where firstSeen[transfer.id] == nil { firstSeen[transfer.id] = Date() }
        firstSeen = firstSeen.filter { id, _ in active.contains(where: { $0.id == id }) }

        if let selected = selectedActive(active),
           Date().timeIntervalSince(firstSeen[selected.id] ?? Date()) >= minimumVisibleDelay {
            presentedTransferIDs.insert(selected.id)
            sendThrottled(Self.activePayload(transfer: selected, activeCount: active.count, command: published ? "update" : "create"))
            presentedEjectVolumeID = nil
            return
        }

        if !active.isEmpty {
            scheduleRefresh(transfers)
            return
        }

        if let terminal = Self.eligibleTerminal(in: transfers, presentedTransferIDs: presentedTransferIDs) {
            presentedEjectVolumeID = terminal.state == .completed ? terminal.destinationVolumeID : nil
            sendThrottled(Self.terminalPayload(
                transfer: terminal,
                command: published ? "update" : "create",
                canEject: presentedEjectVolumeID != nil,
                supportsPresentSneakPeek: supportsPresentSneakPeek
            ))
        } else if published {
            trySend(Self.dismissPayload(activityID: Self.activityID))
            published = false
            lastPayloadSignature = nil
            presentedEjectVolumeID = nil
        }
    }

    public func showMounted(_ volume: Volume) {
        var details = "\(volume.name) connected"
        if let free = TransferFormatters.bytes(volume.availableCapacity) { details += " · \(free) free" }
        showTransientPeek(
            activityID: "transfer-center.volume-event",
            text: details,
            systemImage: "externaldrive.fill",
            useDriveArtwork: true,
            status: "success",
            tint: "blue",
            rightTint: "green"
        )
    }

    public func showUnmounted(_ volume: Volume) {
        showTransientPeek(
            activityID: "transfer-center.volume-event",
            text: "\(volume.name) disconnected",
            systemImage: "externaldrive.fill",
            useDriveArtwork: true,
            rightSystemImage: "xmark",
            status: "success",
            tint: "blue",
            rightTint: "gray"
        )
    }

    public func showEjectResult(_ result: Result<Void, EjectError>, volumeName: String) {
        let text: String
        let symbol: String
        let statusValue: String
        let tint: String
        switch result {
        case .success:
            text = "\(volumeName) ejected"
            symbol = "checkmark.circle.fill"
            statusValue = "success"
            tint = "green"
        case .failure(let error):
            text = error.localizedDescription
            symbol = "exclamationmark.triangle.fill"
            statusValue = "failed"
            tint = "red"
        }
        showTransientPeek(
            activityID: "transfer-center.eject-result",
            text: text,
            systemImage: symbol,
            status: statusValue,
            tint: tint
        )
    }

    public static func activePayload(transfer: Transfer, activeCount: Int, command: String) -> [String: Any] {
        let percent = TransferFormatters.percentage(transfer.fractionCompleted)
        var centerParts = [transfer.displayName]
        if let percent { centerParts.append(percent) }
        if let bytes = byteProgress(transfer) { centerParts.append(bytes) }
        if let speed = TransferFormatters.throughput(transfer.bytesPerSecond) { centerParts.append(speed) }
        if let eta = TransferFormatters.duration(transfer.estimatedSecondsRemaining) { centerParts.append("\(eta) left") }
        if let files = fileProgress(transfer) { centerParts.append(files) }
        if activeCount > 1 { centerParts.insert("\(activeCount) transfers", at: 0) }

        let compact: [String: Any] = [
            "leftSlot": driveImage(id: "transfer-drive"),
            "rightSlot": progress(id: "transfer-progress-compact", value: transfer.fractionCompleted),
        ]
        return base(command: command, activityID: activityID, surfaces: [
            "compactLiveActivity": compact,
            "sneakPeek": [
                "leftSlot": progress(id: "transfer-progress", value: transfer.fractionCompleted),
                "center": text(id: "transfer-details", value: bounded(centerParts.joined(separator: " · ")), style: "marquee"),
            ],
        ])
    }

    public static func terminalPayload(
        transfer: Transfer,
        command: String,
        canEject: Bool,
        supportsPresentSneakPeek: Bool = false
    ) -> [String: Any] {
        let title: String
        let symbol: String
        let tint: String
        switch transfer.state {
        case .completed: title = "Transfer complete"; symbol = "checkmark.circle.fill"; tint = "green"
        case .cancelled: title = "Transfer cancelled"; symbol = "xmark.circle.fill"; tint = "orange"
        case .volumeDisconnected: title = "Drive disconnected · Transfer interrupted"; symbol = "externaldrive.badge.exclamationmark"; tint = "red"
        default: title = transfer.failureDescription ?? "Transfer failed"; symbol = "exclamationmark.triangle.fill"; tint = "red"
        }
        var details = [title]
        if let volumeName = transfer.volumeName { details.append(volumeName) }
        if let bytes = TransferFormatters.bytes(transfer.bytesTotal ?? transfer.bytesCompleted) { details.append(bytes) }
        if let duration = TransferFormatters.duration(transfer.completedAt?.timeIntervalSince(transfer.startedAt)) { details.append(duration) }

        var sneak: [String: Any] = [
            "leftSlot": image(id: "transfer-result", symbol: symbol, tint: tint),
            "center": text(id: "transfer-result-text", value: bounded(details.joined(separator: " · ")), style: "marquee"),
        ]
        if canEject {
            sneak["rightSlot"] = button(id: "transfer-eject", actionID: "eject", symbol: "eject.fill")
        }
        let compact: [String: Any] = [
            "leftSlot": driveImage(id: "transfer-result-compact"),
            // Completed transfers show a plain checkmark; the circled
            // status badge is reserved for failures and interruptions.
            "rightSlot": transfer.state == .completed
                ? image(id: "transfer-result-status", symbol: "checkmark", tint: tint)
                : status(id: "transfer-result-status", value: "failed", tint: tint),
        ]
        return base(command: command, activityID: activityID, surfaces: [
            "compactLiveActivity": compact,
            "sneakPeek": sneak,
        ], presentSneakPeekSeconds: supportsPresentSneakPeek ? 2 : nil)
    }

    public static func peekPayload(
        activityID: String,
        text value: String,
        systemImage: String,
        useDriveArtwork: Bool = false,
        rightSystemImage: String? = nil,
        status statusValue: String = "success",
        tint: String = "blue",
        rightTint: String? = nil,
        supportsPresentSneakPeek: Bool = false
    ) -> [String: Any] {
        let trailing: [String: Any]
        if let rightSystemImage {
            trailing = image(id: "peek-trailing-icon", symbol: rightSystemImage, tint: rightTint ?? tint)
        } else if statusValue == "success" {
            // Plain checkmark without the circled status badge.
            trailing = image(id: "peek-status", symbol: "checkmark", tint: rightTint ?? tint)
        } else {
            trailing = status(id: "peek-status", value: statusValue, tint: rightTint ?? tint)
        }
        let compact: [String: Any] = [
            "leftSlot": useDriveArtwork ? driveImage(id: "peek-icon") : image(id: "peek-icon", symbol: systemImage, tint: tint),
            "rightSlot": trailing,
        ]
        return base(command: "create", activityID: activityID, surfaces: [
            "compactLiveActivity": compact,
            "sneakPeek": [
                "leftSlot": useDriveArtwork ? driveImage(id: "peek-detail-icon") : image(id: "peek-detail-icon", symbol: systemImage, tint: tint),
                "center": text(id: "peek-detail", value: bounded(value), style: "marquee"),
            ],
        ], presentSneakPeekSeconds: supportsPresentSneakPeek ? 2 : nil)
    }

    public static func dismissPayload(activityID: String) -> [String: Any] {
        ["schemaVersion": 1, "requestID": UUID().uuidString, "type": "dismiss", "activityID": activityID]
    }

    static func eligibleTerminal(in transfers: [Transfer], presentedTransferIDs: Set<String>) -> Transfer? {
        transfers.filter {
            !$0.state.isActive && $0.provider != .fsevents && presentedTransferIDs.contains($0.id)
        }.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func selectedActive(_ transfers: [Transfer]) -> Transfer? {
        transfers.max {
            if $0.provider.priority != $1.provider.priority { return $0.provider.priority < $1.provider.priority }
            return $0.updatedAt < $1.updatedAt
        }
    }

    private func scheduleRefresh(_ transfers: [Transfer]) {
        guard pendingWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pendingWorkItem = nil; self?.render(transfers) }
        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumVisibleDelay, execute: work)
    }

    private func sendThrottled(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let signature = String(data: data, encoding: .utf8), signature != lastPayloadSignature else { return }
        let delay = max(0, minimumUpdateInterval - Date().timeIntervalSince(lastSentAt))
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkItem = nil
            self.trySend(payload)
            self.lastPayloadSignature = signature
            self.lastSentAt = Date()
            self.published = true
        }
        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func trySend(_ payload: [String: Any]) {
        do { try bridge.send(payload) }
        catch { Logger.shared.warning("DynamicLake send failed: \(error.localizedDescription)") }
    }

    private func showTransientPeek(
        activityID: String,
        text: String,
        systemImage: String,
        useDriveArtwork: Bool = false,
        rightSystemImage: String? = nil,
        status: String,
        tint: String,
        rightTint: String? = nil
    ) {
        trySend(Self.peekPayload(
            activityID: activityID,
            text: text,
            systemImage: systemImage,
            useDriveArtwork: useDriveArtwork,
            rightSystemImage: rightSystemImage,
            status: status,
            tint: tint,
            rightTint: rightTint,
            supportsPresentSneakPeek: supportsPresentSneakPeek
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.trySend(Self.dismissPayload(activityID: activityID))
        }
    }

    private static func base(
        command: String,
        activityID: String,
        surfaces: [String: Any],
        presentSneakPeekSeconds: Int? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "requestID": UUID().uuidString,
            "type": command,
            "activityID": activityID,
            "title": "Transfer Center",
            "priority": "normal",
            "size": "small",
            "surfaces": surfaces,
        ]
        if let seconds = presentSneakPeekSeconds { payload["presentSneakPeek"] = min(10, max(1, seconds)) }
        return payload
    }

    private static func image(id: String, symbol: String, tint: String) -> [String: Any] {
        ["type": "image", "id": id, "source": "sfSymbol", "systemImage": symbol, "tint": tint]
    }

    private static func driveImage(id: String) -> [String: Any] {
        guard let base64Data = driveArtworkBase64 else {
            return image(id: id, symbol: "externaldrive.fill", tint: "blue")
        }
        return [
            "type": "image",
            "id": id,
            "source": "inlineData",
            "mimeType": "image/png",
            "base64Data": base64Data,
        ]
    }

    private static let driveArtworkBase64: String? = {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let packagePath = environment["DYNAMICLAKE_PLUGIN_PACKAGE"], !packagePath.isEmpty {
            candidates.append(URL(fileURLWithPath: packagePath).appendingPathComponent("drive-transfer-symbol.png"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/drive-transfer-symbol.png"))

        for url in candidates {
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 48 * 1024 else { continue }
            return data.base64EncodedString()
        }
        return nil
    }()

    private static func text(id: String, value: String, style: String) -> [String: Any] {
        ["type": "text", "id": id, "text": value, "style": style, "tint": "white"]
    }

    private static func progress(id: String, value: Double?) -> [String: Any] {
        var component: [String: Any] = ["type": "progress", "id": id, "tint": "blue"]
        if let value { component["value"] = min(1, max(0, value)) }
        return component
    }

    private static func status(id: String, value: String, tint: String) -> [String: Any] {
        ["type": "status", "id": id, "status": value, "tint": tint]
    }

    private static func button(id: String, actionID: String, symbol: String) -> [String: Any] {
        ["type": "button", "id": id, "actionID": actionID, "systemImage": symbol, "shape": "circle", "tint": "blue"]
    }

    private static func byteProgress(_ transfer: Transfer) -> String? {
        guard let completed = TransferFormatters.bytes(transfer.bytesCompleted),
              let total = TransferFormatters.bytes(transfer.bytesTotal) else { return nil }
        return "\(completed) of \(total)"
    }

    private static func fileProgress(_ transfer: Transfer) -> String? {
        guard let completed = transfer.filesCompleted, let total = transfer.filesTotal else { return nil }
        return "\(completed)/\(total) files"
    }

    private static func bounded(_ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(oneLine.prefix(240))
    }
}
