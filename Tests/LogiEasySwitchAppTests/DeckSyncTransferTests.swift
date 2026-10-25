import XCTest
@testable import LogiEasySwitchApp

final class DeckSyncTransferTests: XCTestCase {
    let peer = UUID().uuidString.lowercased()
    let group = UUID().uuidString.lowercased()
    func testLargeSnapshotAssemblesWithManifestFirstOrLastAndDuplicateChunks() throws {
        let original = Data(repeating: 0x61, count: 92_815)
        let transfer = try DeckSyncTransfer.packets(original, source: peer, group: group)
        XCTAssertEqual(transfer.manifest?.partCount, 2)
        XCTAssertTrue(transfer.packets.allSatisfy { $0.payload.count < 60_000 })
        for packets in [transfer.packets, Array(transfer.packets.reversed())] {
            var assembler = DeckSyncAssembler()
            var received: Data?
            for packet in packets {
                let path = packet.suffix.split(separator: "/").map(String.init)
                received = try assembler.receive(packet.payload, path: path, peer: peer, group: group) ?? received
                _ = try assembler.receive(packet.payload, path: path, peer: peer, group: group)
            }
            XCTAssertEqual(received, original)
            XCTAssertEqual(assembler.pendingBytes, 0)
        }
    }
    func testIncompleteAndCorruptSnapshotsCannotApply() throws {
        let original = Data(repeating: 0x61, count: 100_000)
        let transfer = try DeckSyncTransfer.packets(original, source: peer, group: group)
        var assembler = DeckSyncAssembler()
        let manifest = try XCTUnwrap(transfer.packets.last)
        XCTAssertNil(try assembler.receive(manifest.payload, path: [], peer: peer, group: group))
        for (index, packet) in transfer.packets.dropLast().enumerated() {
            var payload = packet.payload
            if index == 0 { payload[0] ^= 1 }
            let path = packet.suffix.split(separator: "/").map(String.init)
            if index == transfer.packets.count - 2 {
                XCTAssertThrowsError(try assembler.receive(payload, path: path, peer: peer, group: group))
            } else { XCTAssertNil(try assembler.receive(payload, path: path, peer: peer, group: group)) }
        }
    }
    func testBrokerDeniedSubscriptionIsReportedInsteadOfWaitingSilently() {
        XCTAssertNoThrow(try MQTTSubscriptionPolicy.validate(Data([0, 1, 0])))
        XCTAssertThrowsError(try MQTTSubscriptionPolicy.validate(Data([0, 1, 0x80]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("denied"))
        }
    }
    func testSmallSnapshotsRemainCompatibleAndTransferLimitsAreEnforced() throws {
        let small = Data("small snapshot".utf8)
        let transfer = try DeckSyncTransfer.packets(small, source: peer, group: group)
        XCTAssertNil(transfer.manifest)
        XCTAssertEqual(transfer.packets.count, 1)
        var assembler = DeckSyncAssembler()
        XCTAssertEqual(try assembler.receive(small, path: [], peer: peer, group: group), small)
        XCTAssertThrowsError(try DeckSyncTransfer.packets(Data(repeating: 0, count: DeckSyncTransfer.maximumSnapshot + 1), source: peer, group: group))
        XCTAssertThrowsError(try assembler.receive(small, path: ["chunks", "bad", "0"], peer: peer, group: group))
        let manifest = DeckSyncManifest(source: peer, group: group, snapshot: String(repeating: "a", count: 64), byteCount: 100000, partCount: 999)
        XCTAssertThrowsError(try DeckSyncTransfer.validate(manifest, peer: peer, group: group))
    }
    @MainActor func testLargeGroupBecomesEditableOnlyAfterWholeSnapshotArrives() throws {
        let name = "DeckSyncTransferTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in })
        sync.settings = DeckSyncSettings(role: .collaborative, source: group)
        var configuration = DeckConfiguration()
        var button = DeckButton()
        button.settings["largeTestValue"] = String(repeating: "a", count: 93000)
        configuration.buttons = [button]
        var document = DeckSharedDocument(group: group)
        try document.edit(from: DeckSharedConfiguration(DeckConfiguration()), to: DeckSharedConfiguration(configuration), writer: peer, device: "Source")
        let data = try JSONEncoder().encode(DeckSharedPeerEnvelope(source: peer, document: document))
        let packets = try DeckSyncTransfer.packets(data, source: peer, group: group).packets.reversed()
        for (index, packet) in packets.enumerated() {
            sync.receiveSharedPacket(packet.payload, path: packet.suffix.split(separator: "/").map(String.init), peer: peer)
            if index < packets.count - 1 { XCTAssertTrue(sync.isReadOnly); XCTAssertTrue(store.configuration.buttons.isEmpty) }
        }
        XCTAssertFalse(sync.isReadOnly)
        XCTAssertEqual(store.configuration.buttons, configuration.buttons)
        sync.stop()
    }
    func testActualSharedGroupFixtureWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHBOARD_SHARED_FIXTURE"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let envelope = try JSONDecoder().decode(DeckSharedPeerEnvelope.self, from: data)
        var assembler = DeckSyncAssembler()
        var assembled: Data?
        for packet in try DeckSyncTransfer.packets(data, source: envelope.source, group: envelope.document.group).packets.reversed() {
            assembled = try assembler.receive(packet.payload, path: packet.suffix.split(separator: "/").map(String.init), peer: envelope.source, group: envelope.document.group) ?? assembled
        }
        XCTAssertEqual(assembled, data)
        let result = try DeckSharedPeerEnvelope.decode(XCTUnwrap(assembled), source: envelope.source, group: envelope.document.group)
        XCTAssertEqual(result.document, envelope.document)
    }
}
