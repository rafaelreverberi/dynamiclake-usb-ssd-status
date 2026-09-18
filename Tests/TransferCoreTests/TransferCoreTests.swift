import XCTest
@testable import TransferCore

final class VolumeClassifierTests: XCTestCase {
    func testRawAvailableCapacityWinsWhenImportantUsageReportsZero() {
        XCTAssertEqual(
            VolumeCapacityResolver.available(raw: 480_215_040, importantUsage: 0),
            480_215_040
        )
    }

    func testImportantUsageCapacityRemainsFallback() {
        XCTAssertEqual(
            VolumeCapacityResolver.available(raw: nil, importantUsage: 1_500_000_000),
            1_500_000_000
        )
    }

    func testInternalDisk() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/"), isInternal: true, isLocal: true)), .internalStorage)
    }

    func testExternalSSD() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/Volumes/T7"), isInternal: false, isLocal: true, isEjectable: true)), .externalLocal)
    }

    func testRemovableUSB() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/Volumes/USB"), isInternal: false, isLocal: true, isRemovable: true)), .removable)
    }

    func testNetworkVolume() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/Volumes/NAS"), isLocal: false)), .network)
    }

    func testDiskImage() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/Volumes/Image"), isInternal: false, isLocal: true, isEjectable: true, deviceProtocol: "Disk Image")), .diskImage)
    }

    func testIncompleteMetadata() {
        XCTAssertEqual(VolumeClassifier.classify(.init(mountURL: URL(fileURLWithPath: "/mystery"))), .unknown)
    }
}

private final class FakeProvider: TransferProvider {
    let name: String
    weak var delegate: TransferProviderDelegate?
    init(_ name: String) { self.name = name }
    func start(volumes: [Volume]) {}
    func update(volumes: [Volume]) {}
    func stop() {}
    func emit(_ event: TransferProviderEvent) { delegate?.transferProvider(self, emitted: event) }
}

final class TransferCoordinatorTests: XCTestCase {
    private func transfer(
        id: String,
        provider: TransferProviderKind,
        volume: String = "volume-1",
        fraction: Double? = nil,
        state: TransferState = .active,
        secondsOffset: TimeInterval = 0
    ) -> Transfer {
        let date = Date().addingTimeInterval(secondsOffset)
        return Transfer(
            id: id,
            kind: provider == .fsevents ? .fileActivity : .copying,
            state: provider == .fsevents ? .indeterminate : state,
            destinationURL: URL(fileURLWithPath: "/Volumes/T7/Project"),
            destinationVolumeID: volume,
            volumeName: "T7",
            displayName: "Copying",
            fractionCompleted: fraction,
            startedAt: date,
            updatedAt: date,
            provider: provider,
            confidence: provider == .foundationProgress ? .exact : .activity
        )
    }

    private func settle(_ coordinator: TransferCoordinator, count: Int, file: StaticString = #filePath, line: UInt = #line) -> [Transfer] {
        let expectation = expectation(description: "coordinator")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        let value = coordinator.snapshot
        XCTAssertEqual(value.count, count, file: file, line: line)
        return value
    }

    func testProgressWinsAndNoDuplicate() {
        let coordinator = TransferCoordinator()
        let fs = FakeProvider("fs")
        let progress = FakeProvider("progress")
        fs.delegate = coordinator
        progress.delegate = coordinator
        fs.emit(.updated(transfer(id: "fs", provider: .fsevents)))
        progress.emit(.updated(transfer(id: "progress", provider: .foundationProgress, fraction: 0.5, secondsOffset: 0.1)))
        let snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].provider, .foundationProgress)
        XCTAssertEqual(snapshot[0].fractionCompleted, 0.5)
    }

    func testCompletionAndCancellation() {
        let coordinator = TransferCoordinator()
        let provider = FakeProvider("progress")
        provider.delegate = coordinator
        provider.emit(.updated(transfer(id: "one", provider: .foundationProgress)))
        provider.emit(.removed(id: "one", finalState: .completed))
        var snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot[0].state, .completed)

        provider.emit(.updated(transfer(id: "two", provider: .foundationProgress, volume: "volume-2")))
        provider.emit(.removed(id: "two", finalState: .cancelled))
        snapshot = settle(coordinator, count: 2)
        XCTAssertEqual(snapshot.first(where: { $0.id == "two" })?.state, .cancelled)
    }

    func testDisconnectedDrive() {
        let coordinator = TransferCoordinator()
        let provider = FakeProvider("progress")
        provider.delegate = coordinator
        provider.emit(.updated(transfer(id: "one", provider: .foundationProgress)))
        coordinator.handleVolumeDisconnected("volume-1")
        let snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot[0].state, .volumeDisconnected)
    }

    func testMultipleConcurrentTransfersRemainSeparate() {
        let coordinator = TransferCoordinator()
        let provider = FakeProvider("progress")
        provider.delegate = coordinator
        provider.emit(.updated(transfer(id: "one", provider: .foundationProgress, volume: "volume-1")))
        var second = transfer(id: "two", provider: .foundationProgress, volume: "volume-2")
        second.destinationURL = URL(fileURLWithPath: "/Volumes/Other/Archive")
        provider.emit(.updated(second))
        XCTAssertEqual(settle(coordinator, count: 2).count, 2)
    }

    func testSequentialFilesOnSameVolumeContinueSingleLogicalTransfer() {
        let coordinator = TransferCoordinator()
        let provider = FakeProvider("progress")
        provider.delegate = coordinator
        provider.emit(.updated(transfer(id: "file-1", provider: .foundationProgress, volume: "volume-1")))
        provider.emit(.removed(id: "file-1", finalState: .completed))
        var snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot[0].state, .completed)
        XCTAssertEqual(snapshot[0].id, "file-1")

        // Next file of the same Finder job starts immediately (new Progress object).
        provider.emit(.updated(transfer(id: "file-2", provider: .foundationProgress, volume: "volume-1")))
        snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot[0].id, "file-1", "Sequential files must not flash an intermediate success")
        XCTAssertTrue(snapshot[0].state.isActive)
        XCTAssertNil(snapshot[0].completedAt)

        provider.emit(.removed(id: "file-2", finalState: .completed))
        snapshot = settle(coordinator, count: 1)
        XCTAssertEqual(snapshot[0].id, "file-1")
        XCTAssertEqual(snapshot[0].state, .completed)
    }

    func testSequentialTransfersOnDifferentVolumesRemainSeparate() {
        let coordinator = TransferCoordinator()
        let provider = FakeProvider("progress")
        provider.delegate = coordinator
        provider.emit(.updated(transfer(id: "file-1", provider: .foundationProgress, volume: "volume-1")))
        provider.emit(.removed(id: "file-1", finalState: .completed))
        _ = settle(coordinator, count: 1)

        provider.emit(.updated(transfer(id: "file-2", provider: .foundationProgress, volume: "volume-2")))
        let snapshot = settle(coordinator, count: 2)
        XCTAssertNotNil(snapshot.first(where: { $0.id == "file-1" }))
        XCTAssertNotNil(snapshot.first(where: { $0.id == "file-2" }))
    }
}

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(TransferFormatters.bytes(1_000_000), "1 MB")
        XCTAssertNil(TransferFormatters.bytes(nil))
    }

    func testPercentageClamps() {
        XCTAssertEqual(TransferFormatters.percentage(0.675), "68%")
        XCTAssertEqual(TransferFormatters.percentage(2), "100%")
        XCTAssertNil(TransferFormatters.percentage(nil))
    }

    func testETAAndThroughput() {
        XCTAssertEqual(TransferFormatters.duration(96), "1m 36s")
        XCTAssertEqual(TransferFormatters.throughput(1_000_000), "1 MB/s")
    }
}

final class DynamicLakeRenderingTests: XCTestCase {
    func testActivePayloadUsesDocumentedSchemaAndNoInventedMetrics() throws {
        let transfer = Transfer(
            id: "one",
            kind: .copying,
            state: .active,
            destinationVolumeID: "volume-1",
            volumeName: "T7",
            displayName: "Copying to T7",
            fractionCompleted: 0.67,
            startedAt: Date(),
            updatedAt: Date(),
            provider: .foundationProgress,
            confidence: .exact
        )
        let payload = DynamicLakeRenderer.activePayload(transfer: transfer, activeCount: 1, command: "create")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 1)
        XCTAssertEqual(payload["type"] as? String, "create")
        let surfaces = try XCTUnwrap(payload["surfaces"] as? [String: Any])
        XCTAssertNotNil(surfaces["compactLiveActivity"])
        XCTAssertNil(surfaces["extraLiveActivity"], "The JSON protocol currently defines only compactLiveActivity and sneakPeek")
        let compact = try XCTUnwrap(surfaces["compactLiveActivity"] as? [String: Any])
        let compactLeft = try XCTUnwrap(compact["leftSlot"] as? [String: Any])
        let compactRight = try XCTUnwrap(compact["rightSlot"] as? [String: Any])
        XCTAssertEqual(compactLeft["source"] as? String, "inlineData")
        XCTAssertEqual(compactLeft["mimeType"] as? String, "image/png")
        let artwork = try XCTUnwrap(compactLeft["base64Data"] as? String)
        XCTAssertLessThanOrEqual(try XCTUnwrap(Data(base64Encoded: artwork)).count, 48 * 1024)
        XCTAssertEqual(compactRight["type"] as? String, "progress")
        XCTAssertNil(compactRight["status"], "progress components do not have a status field")
        let sneak = try XCTUnwrap(surfaces["sneakPeek"] as? [String: Any])
        let center = try XCTUnwrap(sneak["center"] as? [String: Any])
        let text = try XCTUnwrap(center["text"] as? String)
        XCTAssertLessThanOrEqual(text.count, 240)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("/s"), "Missing speed must not be fabricated")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testTerminalPayloadHasSafeEjectActionOnlyWhenAllowed() throws {
        var transfer = Transfer(
            id: "one",
            kind: .copying,
            state: .completed,
            destinationVolumeID: "volume-1",
            volumeName: "T7",
            displayName: "Copying",
            startedAt: Date().addingTimeInterval(-10),
            updatedAt: Date(),
            completedAt: Date(),
            provider: .foundationProgress,
            confidence: .exact
        )
        var payload = DynamicLakeRenderer.terminalPayload(
            transfer: transfer,
            command: "update",
            canEject: true,
            supportsPresentSneakPeek: true
        )
        XCTAssertEqual(payload["presentSneakPeek"] as? Int, 2)
        var surfaces = try XCTUnwrap(payload["surfaces"] as? [String: Any])
        var sneak = try XCTUnwrap(surfaces["sneakPeek"] as? [String: Any])
        XCTAssertNotNil(sneak["rightSlot"])
        var compact = try XCTUnwrap(surfaces["compactLiveActivity"] as? [String: Any])
        var compactRight = try XCTUnwrap(compact["rightSlot"] as? [String: Any])
        XCTAssertEqual(compactRight["type"] as? String, "image")
        XCTAssertEqual(compactRight["systemImage"] as? String, "checkmark")
        XCTAssertEqual(compactRight["tint"] as? String, "green")
        XCTAssertNil(compactRight["status"], "Completed transfers show a plain checkmark, not a circled status badge")

        transfer.state = .failed
        payload = DynamicLakeRenderer.terminalPayload(transfer: transfer, command: "update", canEject: false)
        surfaces = try XCTUnwrap(payload["surfaces"] as? [String: Any])
        sneak = try XCTUnwrap(surfaces["sneakPeek"] as? [String: Any])
        XCTAssertNil(sneak["rightSlot"])
        XCTAssertNil(payload["presentSneakPeek"], "Feature-gated fields must be omitted for older hosts")
        compact = try XCTUnwrap(surfaces["compactLiveActivity"] as? [String: Any])
        compactRight = try XCTUnwrap(compact["rightSlot"] as? [String: Any])
        XCTAssertEqual(compactRight["type"] as? String, "status")
        XCTAssertEqual(compactRight["status"] as? String, "failed")
    }

    func testDisconnectedVolumePeekUsesNeutralXmarkAndIsFeatureGated() throws {
        let payload = DynamicLakeRenderer.peekPayload(
            activityID: "transfer-center.volume-event",
            text: "Backup SSD disconnected",
            systemImage: "externaldrive.fill",
            useDriveArtwork: true,
            rightSystemImage: "xmark",
            tint: "blue",
            rightTint: "gray",
            supportsPresentSneakPeek: true
        )
        XCTAssertEqual(payload["presentSneakPeek"] as? Int, 2)
        let surfaces = try XCTUnwrap(payload["surfaces"] as? [String: Any])
        let compact = try XCTUnwrap(surfaces["compactLiveActivity"] as? [String: Any])
        let left = try XCTUnwrap(compact["leftSlot"] as? [String: Any])
        let right = try XCTUnwrap(compact["rightSlot"] as? [String: Any])
        XCTAssertEqual(left["source"] as? String, "inlineData")
        XCTAssertEqual(right["type"] as? String, "image")
        XCTAssertEqual(right["systemImage"] as? String, "xmark")
        XCTAssertEqual(right["tint"] as? String, "gray")

        let compatible = DynamicLakeRenderer.peekPayload(
            activityID: "transfer-center.volume-event",
            text: "Backup SSD connected",
            systemImage: "externaldrive.fill"
        )
        XCTAssertNil(compatible["presentSneakPeek"])
        let compatibleSurfaces = try XCTUnwrap(compatible["surfaces"] as? [String: Any])
        let compatibleCompact = try XCTUnwrap(compatibleSurfaces["compactLiveActivity"] as? [String: Any])
        let compatibleRight = try XCTUnwrap(compatibleCompact["rightSlot"] as? [String: Any])
        XCTAssertEqual(compatibleRight["type"] as? String, "image")
        XCTAssertEqual(compatibleRight["systemImage"] as? String, "checkmark")
        XCTAssertNil(compatibleRight["status"], "Connected drives show a plain checkmark, not a circled status badge")
    }

    func testCompletionIsEligibleOnlyAfterThatTransferWasPresented() {
        let completed = Transfer(
            id: "preflight",
            kind: .copying,
            state: .completed,
            destinationVolumeID: "volume-1",
            volumeName: "USB",
            displayName: "Copying",
            startedAt: Date(),
            updatedAt: Date(),
            completedAt: Date(),
            provider: .foundationProgress,
            confidence: .exact
        )

        XCTAssertNil(DynamicLakeRenderer.eligibleTerminal(
            in: [completed],
            presentedTransferIDs: []
        ))
        XCTAssertEqual(DynamicLakeRenderer.eligibleTerminal(
            in: [completed],
            presentedTransferIDs: [completed.id]
        )?.id, completed.id)
    }
}

final class ProgressLifecycleGateTests: XCTestCase {
    func testAlreadyFinishedPublicationIsSuppressed() {
        var gate = ProgressLifecycleGate()
        XCTAssertFalse(gate.shouldEmit(.completed))
        XCTAssertFalse(gate.hasSeenNonterminal)
        XCTAssertFalse(gate.hasEmittedTerminal)
    }

    func testCompletionFollowsObservedActivityExactlyOnce() {
        var gate = ProgressLifecycleGate()
        XCTAssertTrue(gate.shouldEmit(.active))
        XCTAssertTrue(gate.shouldEmit(.completed))
        XCTAssertFalse(gate.shouldEmit(.completed))
        XCTAssertTrue(gate.hasSeenNonterminal)
        XCTAssertTrue(gate.hasEmittedTerminal)
    }

    func testCancellationWithoutObservedActivityIsSuppressed() {
        var gate = ProgressLifecycleGate()
        XCTAssertFalse(gate.shouldEmit(.cancelled))
    }
}
