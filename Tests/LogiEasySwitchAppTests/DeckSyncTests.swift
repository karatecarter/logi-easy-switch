import XCTest
@testable import LogiEasySwitchApp

final class DeckSyncTests: XCTestCase {
    func testSharedConfigExcludesMachineLocalSettingsAndPreservesOverrides() throws {
        var source = DeckConfiguration()
        source.hotkey = Shortcut(keyCode: 1, modifiers: 1, label: "S")
        source.homeAssistantURL = "https://source.example"
        var script = DeckButton()
        script.kind = "python"
        script.settings = ["path": "/source/script.py", "interpreter": "/source/python", "other": "shared"]
        source.buttons = [script]
        let shared = DeckSharedConfiguration(source)
        let json = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        XCTAssertFalse(json.contains("source.example"))
        XCTAssertFalse(json.contains("source/script.py"))
        XCTAssertFalse(json.contains("source/python"))
        XCTAssertFalse(json.contains("hotkey"))
        var local = DeckConfiguration()
        local.homeAssistantURL = "https://local.example"
        local.hotkey = Shortcut(keyCode: 2, modifiers: 2, label: "D")
        script.settings = ["path": "/local/script.py", "interpreter": "/local/python"]
        local.buttons = [script]
        let merged = shared.applying(to: local)
        XCTAssertEqual(merged.homeAssistantURL, local.homeAssistantURL)
        XCTAssertEqual(merged.hotkey, local.hotkey)
        XCTAssertEqual(merged.buttons[0].settings["path"], "/local/script.py")
        XCTAssertEqual(merged.buttons[0].settings["other"], "shared")
        XCTAssertNil(shared.applying(to: DeckConfiguration()).buttons[0].settings["path"])
    }

    func testEnvelopeRejectsWrongSourceSchemaOversizeAndInvalidHierarchy() throws {
        let source = UUID().uuidString.lowercased()
        var configuration = DeckConfiguration()
        var snapshot = DeckSyncEnvelope(source: source, revision: 1, configuration: DeckSharedConfiguration(configuration))
        XCTAssertNoThrow(try DeckSyncEnvelope.decode(JSONEncoder().encode(snapshot), source: source))
        XCTAssertThrowsError(try DeckSyncEnvelope.decode(JSONEncoder().encode(snapshot), source: "wrong"))
        snapshot.schema = 99
        XCTAssertThrowsError(try DeckSyncEnvelope.decode(JSONEncoder().encode(snapshot), source: source))
        XCTAssertThrowsError(try DeckSyncEnvelope.decode(Data(repeating: 0, count: DeckSyncEnvelope.maximumPayload + 1), source: source))
        var folder = DeckButton()
        folder.kind = "folder"
        folder.parentID = folder.id
        configuration.buttons = [folder]
        XCTAssertThrowsError(try DeckSharedConfiguration(configuration).validate())
        folder.parentID = nil
        configuration.buttons = [folder, folder]
        XCTAssertThrowsError(try DeckSharedConfiguration(configuration).validate())
        configuration.buttons = [DeckButton()]
        configuration.buttons[0].parentID = UUID()
        XCTAssertThrowsError(try DeckSharedConfiguration(configuration).validate())
    }

    @MainActor func testFollowerAppliesNewSnapshotsBacksUpAndRejectsRollback() throws {
        let name = "DeckSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        var backupCount = 0
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in backupCount += 1 })
        let source = UUID().uuidString.lowercased()
        sync.settings = DeckSyncSettings(role: .follower, source: source)
        var shared = DeckConfiguration()
        shared.buttons = DeckThermostatPreset.make()
        var snapshot = DeckSyncEnvelope(source: source, revision: 3, configuration: DeckSharedConfiguration(shared))
        sync.receive(try JSONEncoder().encode(snapshot))
        XCTAssertEqual(store.configuration.buttons.count, shared.buttons.count)
        XCTAssertEqual(backupCount, 1)
        sync.receive(try JSONEncoder().encode(snapshot))
        XCTAssertEqual(backupCount, 1)
        snapshot.revision = 2
        snapshot.configuration.buttons = []
        sync.receive(try JSONEncoder().encode(snapshot))
        XCTAssertEqual(store.configuration.buttons.count, shared.buttons.count)
        snapshot.revision = 3
        sync.receive(try JSONEncoder().encode(snapshot))
        XCTAssertTrue(sync.status.contains("conflicting"))
        XCTAssertEqual(store.configuration.buttons.count, shared.buttons.count)
        snapshot.revision = 4
        sync.receive(try JSONEncoder().encode(snapshot))
        XCTAssertTrue(store.configuration.buttons.isEmpty)
        XCTAssertEqual(backupCount, 2)
        XCTAssertEqual(DeckStore(defaults: defaults).configuration, store.configuration)
    }

    @MainActor func testBackupFailureDoesNotReplaceConfigurationOrAdvanceRevision() throws {
        let name = "DeckSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        var fail = true
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in
            if fail { throw DeckError.message("Backup disk unavailable") }
        })
        let source = UUID().uuidString.lowercased()
        sync.settings = DeckSyncSettings(role: .follower, source: source)
        var incoming = DeckConfiguration()
        incoming.buttons = [DeckButton()]
        let data = try JSONEncoder().encode(DeckSyncEnvelope(source: source, revision: 1, configuration: DeckSharedConfiguration(incoming)))
        sync.receive(data)
        XCTAssertTrue(store.configuration.buttons.isEmpty)
        fail = false
        sync.receive(data)
        XCTAssertEqual(store.configuration.buttons.count, 1)
    }
}
