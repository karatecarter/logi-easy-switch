import XCTest
@testable import LogiEasySwitchApp

final class DeckSyncScopeTests: XCTestCase {
    func testDefaultAndLegacyButtonsSyncUnlessExplicitlyUnchecked() throws {
        var button = DeckButton()
        var configuration = DeckConfiguration()
        configuration.buttons = [button]
        XCTAssertEqual(DeckSharedConfiguration(configuration).buttons.count, 1)
        let legacy = try JSONDecoder().decode(DeckButton.self, from: JSONEncoder().encode(button))
        XCTAssertNil(legacy.syncWithGroup)
        button.syncWithGroup = false
        configuration.buttons = [button]
        XCTAssertTrue(DeckSharedConfiguration(configuration).buttons.isEmpty)
    }
    func testLocalFolderExcludesDescendantsAndIncomingUpdatesPreserveThem() throws {
        var local = DeckConfiguration()
        local.buttons = DeckThermostatPreset.make()
        local.buttons[0].syncWithGroup = false
        let shared = DeckSharedConfiguration(local)
        XCTAssertTrue(shared.buttons.isEmpty)
        let applied = shared.applying(to: local)
        XCTAssertEqual(applied.buttons, local.buttons)
        XCTAssertNoThrow(try DeckSharedConfiguration(applied).validate())
    }
    func testIncomingSnapshotCannotOverwriteLocalButtonWithSameID() {
        var button = DeckButton()
        button.name = "Shared"
        var remote = DeckConfiguration(); remote.buttons = [button]
        button.syncWithGroup = false
        button.name = "My local version"
        var local = DeckConfiguration(); local.buttons = [button]
        XCTAssertEqual(DeckSharedConfiguration(remote).applying(to: local).buttons[0], button)
    }
    func testDeletedSharedParentDoesNotHideLocalChild() {
        var folder = DeckButton(); folder.kind = "folder"
        var child = DeckButton(); child.parentID = folder.id; child.syncWithGroup = false
        var local = DeckConfiguration(); local.buttons = [folder, child]
        let updated = DeckSharedConfiguration(DeckConfiguration()).applying(to: local)
        XCTAssertEqual(updated.buttons.count, 1)
        XCTAssertEqual(updated.buttons[0].id, child.id)
        XCTAssertNil(updated.buttons[0].parentID)
        XCTAssertEqual(updated.buttons[0].syncWithGroup, false)
    }
    @MainActor func testEditingLocalCopyDoesNotDeleteRemoteConflictAgain() throws {
        let name = "DeckSyncScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        store.configuration.buttons = [DeckButton()]
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in })
        store.onChange = { [weak sync] in sync?.localConfigurationChanged() }
        sync.createSharedGroup()
        var other = try XCTUnwrap(sync.sharedDocument)
        let base = other.materialized()
        var remoteEdit = base
        remoteEdit.buttons[0].name = "Remote change"
        let peer = UUID().uuidString.lowercased()
        try other.edit(from: base, to: remoteEdit, writer: peer, device: "Other Mac")
        store.configuration.buttons[0].syncWithGroup = false
        sync.receiveShared(try JSONEncoder().encode(DeckSharedPeerEnvelope(source: peer, document: other)), peer: peer)
        XCTAssertEqual(store.configuration.buttons[0].syncWithGroup, false)
        let document = sync.sharedDocument
        store.configuration.buttons[0].name = "Only local edit"
        XCTAssertEqual(sync.sharedDocument, document)
        sync.stop()
    }

    func testOptingOutDeletesSharedCopyButKeepsLocalAndReenableSharesAgain() throws {
        let group = UUID().uuidString.lowercased(), actor = UUID().uuidString.lowercased()
        var local = DeckConfiguration(); local.buttons = [DeckButton()]
        var document = DeckSharedDocument(group: group)
        try document.edit(from: DeckSharedConfiguration(DeckConfiguration()), to: DeckSharedConfiguration(local), writer: actor, device: "Mac")
        local.buttons[0].syncWithGroup = false
        try document.edit(from: document.materialized(), to: DeckSharedConfiguration(local), writer: actor, device: "Mac")
        XCTAssertTrue(document.materialized().buttons.isEmpty)
        XCTAssertEqual(document.materialized().applying(to: local).buttons.count, 1)
        local.buttons[0].syncWithGroup = true
        try document.edit(from: document.materialized(), to: DeckSharedConfiguration(local), writer: actor, device: "Mac")
        XCTAssertEqual(document.materialized().buttons.count, 1)
    }
}
