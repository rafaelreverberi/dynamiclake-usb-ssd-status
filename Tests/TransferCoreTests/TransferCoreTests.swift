import XCTest
@testable import TransferCore

final class VolumeClassifierTests: XCTestCase {
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
        let compactRight = try XCTUnwrap(compact["rightSlot"] as? [String: Any])
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

        transfer.state = .failed
        payload = DynamicLakeRenderer.terminalPayload(transfer: transfer, command: "update", canEject: false)
        surfaces = try XCTUnwrap(payload["surfaces"] as? [String: Any])
        sneak = try XCTUnwrap(surfaces["sneakPeek"] as? [String: Any])
        XCTAssertNil(sneak["rightSlot"])
        XCTAssertNil(payload["presentSneakPeek"], "Feature-gated fields must be omitted for older hosts")
    }
}
