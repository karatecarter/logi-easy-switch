import XCTest
@testable import LogiEasySwitchApp

final class DeckSharedDocumentTests: XCTestCase {
    let group = UUID().uuidString.lowercased()
    let a = UUID().uuidString.lowercased()
    let b = UUID().uuidString.lowercased()
    private func seeded(_ group: String, writer: String) throws -> DeckSharedDocument {
        var configuration = DeckConfiguration()
        var one = DeckButton(); one.name = "One"
        var two = DeckButton(); two.name = "Two"
        configuration.buttons = [one, two]
        var document = DeckSharedDocument(group: group)
        try document.edit(from: DeckSharedConfiguration(DeckConfiguration()), to: DeckSharedConfiguration(configuration), writer: writer, device: "Mac A")
        return document
    }
    func testDifferentButtonsMergeAndConvergeRegardlessOfDeliveryOrder() throws {
        let base = try seeded(group, writer: a)
        var left = base, right = base
        var l = base.materialized(), r = base.materialized()
        l.buttons[0].name = "Edited on A"; r.buttons[1].name = "Edited on B"
        try left.edit(from: base.materialized(), to: l, writer: a, device: "A")
        try right.edit(from: base.materialized(), to: r, writer: b, device: "B")
        let merged = try left.merging(right)
        XCTAssertEqual(merged, try right.merging(left))
        XCTAssertEqual(merged.materialized().buttons.map(\.name), ["Edited on A", "Edited on B"])
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(merged, try merged.merging(right))
    }
    func testConcurrentSameButtonEditsArePreservedAndResolutionPropagates() throws {
        let base = try seeded(group, writer: a)
        var left = base, right = base
        var l = base.materialized(), r = base.materialized()
        l.buttons[0].name = "A version"; r.buttons[0].name = "B version"
        try left.edit(from: base.materialized(), to: l, writer: a, device: "A")
        try right.edit(from: base.materialized(), to: r, writer: b, device: "B")
        var merged = try left.merging(right)
        let key = try XCTUnwrap(merged.conflicts.first)
        XCTAssertEqual(merged.records[key]?.count, 2)
        let chosen = try XCTUnwrap(merged.records[key]?.first { $0.writer == b })
        try merged.resolve(key: key, versionID: chosen.id, writer: a, device: "A")
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(try merged.merging(right).materialized().buttons[0].name, "B version")
        XCTAssertEqual(try merged.merging(left).conflicts, [])
    }
    func testDeletionIsNotResurrectedByStaleSnapshots() throws {
        let base = try seeded(group, writer: a)
        var newer = base
        var edited = base.materialized()
        edited.buttons.removeFirst()
        try newer.edit(from: base.materialized(), to: edited, writer: b, device: "B")
        XCTAssertEqual(try newer.merging(base).materialized().buttons.count, 1)
        XCTAssertTrue(try newer.merging(base).conflicts.isEmpty)
    }
    func testConcurrentCreationKeepsBothButtonsAndIdenticalValuesDoNotConflict() throws {
        let base = try seeded(group, writer: a)
        var left = base, right = base
        var l = base.materialized(), r = base.materialized()
        var x = DeckButton(); x.name = "New A"
        var y = DeckButton(); y.name = "New B"
        l.buttons.append(x); r.buttons.append(y)
        try left.edit(from: base.materialized(), to: l, writer: a, device: "A")
        try right.edit(from: base.materialized(), to: r, writer: b, device: "B")
        let merged = try left.merging(right)
        XCTAssertEqual(merged.materialized().buttons.count, 4)
        XCTAssertTrue(merged.conflicts.isEmpty)
        var independent = DeckSharedDocument(group: group)
        try independent.edit(from: DeckSharedConfiguration(DeckConfiguration()), to: base.materialized(), writer: b, device: "B")
        XCTAssertTrue(try base.merging(independent).conflicts.isEmpty)
    }
    func testConcurrentFolderDeletionPromotesSurvivingEditedChildren() throws {
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        var base = DeckSharedDocument(group: group)
        try base.edit(from: DeckSharedConfiguration(DeckConfiguration()), to: DeckSharedConfiguration(configuration), writer: a, device: "A")
        var left = base, right = base
        var l = base.materialized(), r = base.materialized()
        l.buttons.removeAll()
        r.buttons[1].name = "Edited child"
        try left.edit(from: base.materialized(), to: l, writer: a, device: "A")
        try right.edit(from: base.materialized(), to: r, writer: b, device: "B")
        let merged = try left.merging(right)
        XCTAssertFalse(merged.conflicts.isEmpty)
        XCTAssertNoThrow(try merged.materialized().validate())
        XCTAssertTrue(merged.materialized().buttons.allSatisfy { $0.parentID == nil })
    }
    func testThreePeerMergeIsAssociativeAndDuplicateSafe() throws {
        let base = try seeded(group, writer: a)
        let c = UUID().uuidString.lowercased()
        var peers: [DeckSharedDocument] = []
        for (actor, name) in [(a, "A"), (b, "B"), (c, "C")] {
            var peer = base
            var updated = base.materialized()
            updated.buttons[0].name = name
            try peer.edit(from: base.materialized(), to: updated, writer: actor, device: name)
            peers.append(peer)
        }
        let left = try peers[0].merging(peers[1]).merging(peers[2])
        let right = try peers[0].merging(peers[1].merging(peers[2]))
        XCTAssertEqual(left, right)
        XCTAssertEqual(left, try peers[2].merging(peers[0]).merging(peers[1]))
        XCTAssertEqual(left, try left.merging(left))
        XCTAssertEqual(left.conflicts.count, 1)
        XCTAssertEqual(left.records[left.conflicts[0]]?.count, 3)
    }
    func testStalePeerCannotUndoResolvedDeletionConflict() throws {
        let base = try seeded(group, writer: a)
        var left = base, right = base
        var removed = base.materialized(), edited = base.materialized()
        let removedID = removed.buttons.removeFirst().id
        edited.buttons[0].name = "Offline edit"
        try left.edit(from: base.materialized(), to: removed, writer: a, device: "A")
        try right.edit(from: base.materialized(), to: edited, writer: b, device: "B")
        var merged = try left.merging(right)
        let key = removedID.uuidString.lowercased()
        let deletion = try XCTUnwrap(merged.records[key]?.first { $0.button == nil })
        try merged.resolve(key: key, versionID: deletion.id, writer: a, device: "A")
        XCTAssertFalse(try merged.merging(right).materialized().buttons.contains { $0.id == removedID })
        XCTAssertTrue(try merged.merging(right).conflicts.isEmpty)
    }

    @MainActor func testTwoCoordinatorsConvergeAfterIndependentOfflineEdits() throws {
        let firstName = "DeckSharedDocumentTests.\(UUID().uuidString)"
        let secondName = "DeckSharedDocumentTests.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstName))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondName))
        defer {
            firstDefaults.removePersistentDomain(forName: firstName)
            secondDefaults.removePersistentDomain(forName: secondName)
        }
        let firstStore = DeckStore(defaults: firstDefaults)
        let secondStore = DeckStore(defaults: secondDefaults)
        firstStore.configuration.buttons = [DeckButton(), DeckButton()]
        let first = DeckSyncCoordinator(store: firstStore, defaults: firstDefaults, backup: { _ in })
        let second = DeckSyncCoordinator(store: secondStore, defaults: secondDefaults, backup: { _ in })
        firstStore.onChange = { [weak first] in first?.localConfigurationChanged() }
        secondStore.onChange = { [weak second] in second?.localConfigurationChanged() }
        first.createSharedGroup()
        second.settings = DeckSyncSettings(role: .collaborative, source: first.settings.source)
        let seed = try XCTUnwrap(first.sharedDocument)
        second.receiveShared(try JSONEncoder().encode(DeckSharedPeerEnvelope(source: first.publisherID, document: seed)), peer: first.publisherID)
        XCTAssertFalse(first.isReadOnly)
        XCTAssertFalse(second.isReadOnly)
        firstStore.configuration.buttons[0].name = "First Mac edit"
        secondStore.configuration.buttons[1].name = "Second Mac edit"
        let left = try XCTUnwrap(first.sharedDocument)
        let right = try XCTUnwrap(second.sharedDocument)
        first.receiveShared(try JSONEncoder().encode(DeckSharedPeerEnvelope(source: second.publisherID, document: right)), peer: second.publisherID)
        second.receiveShared(try JSONEncoder().encode(DeckSharedPeerEnvelope(source: first.publisherID, document: left)), peer: first.publisherID)
        XCTAssertEqual(firstStore.configuration.buttons.map(\.name), ["First Mac edit", "Second Mac edit"])
        XCTAssertEqual(firstStore.configuration.buttons, secondStore.configuration.buttons)
        XCTAssertEqual(first.sharedDocument, second.sharedDocument)
        let clock = first.sharedDocument?.clock
        firstStore.configuration.homeAssistantURL = "https://local-only.example"
        XCTAssertEqual(first.sharedDocument?.clock, clock)
        first.stop(); second.stop()
    }

    @MainActor func testPeerReceivesRemoteAndPersistsOfflineEditsWithoutEchoing() throws {
        let name = "DeckSharedDocumentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in })
        sync.settings = DeckSyncSettings(role: .collaborative, source: group)
        store.onChange = { [weak sync] in sync?.localConfigurationChanged() }
        let base = try seeded(group, writer: a)
        sync.receiveShared(try JSONEncoder().encode(DeckSharedPeerEnvelope(source: a, document: base)), peer: a)
        XCTAssertTrue(sync.sharedReady)
        XCTAssertEqual(sync.sharedDocument?.clock, base.clock)
        store.configuration.buttons[0].name = "Offline edit"
        XCTAssertEqual(sync.sharedDocument?.materialized().buttons[0].name, "Offline edit")
        XCTAssertEqual(sync.sharedDocument?.clock[sync.publisherID], 1)
        let reloaded = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in })
        reloaded.reconnect()
        XCTAssertEqual(reloaded.sharedDocument, sync.sharedDocument)
        sync.stop(); reloaded.stop()
    }
}
