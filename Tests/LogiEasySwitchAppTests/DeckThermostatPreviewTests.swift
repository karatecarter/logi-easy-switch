import XCTest
@testable import LogiEasySwitchApp

final class DeckThermostatPreviewTests: XCTestCase {
    private func fixture() -> (DeckConfiguration, DeckButton, UUID) {
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        return (configuration, configuration.buttons[1], configuration.buttons[0].id)
    }
    func testLegacyParameterMigratesOnlyPresetControlsAndPreservesExplicitIncrement() throws {
        var (configuration, _, _) = fixture()
        configuration.buttons[1].settings["data"] = #"{"incr":1,"extra":"keep"}"#
        configuration.buttons[2].settings["data"] = #"{"incr":-1,"increment":-0.5}"#
        var custom = DeckButton()
        custom.kind = "homeassistant"
        custom.settings["data"] = #"{"incr":2}"#
        configuration.buttons.append(custom)
        let migrated = configuration.migratingLegacyThermostatIncrement()
        let plus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(migrated.buttons[1].settings["data"]!.utf8)) as? [String: Any])
        XCTAssertEqual(plus["increment"] as? Int, 1)
        XCTAssertNil(plus["incr"])
        XCTAssertEqual(plus["extra"] as? String, "keep")
        let minus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(migrated.buttons[2].settings["data"]!.utf8)) as? [String: Any])
        XCTAssertEqual(minus["increment"] as? Double, -0.5)
        XCTAssertNil(minus["incr"])
        XCTAssertEqual(migrated.buttons.last, custom)
        XCTAssertEqual(migrated.migratingLegacyThermostatIncrement(), migrated)
    }

    func testImmediatePreviewSurvivesOldReadbackUntilConfirmation() throws {
        let (configuration, action, groupID) = fixture()
        let now = Date()
        var preview = DeckThermostatPreview()
        let (_, text) = try XCTUnwrap(preview.begin(action: action, configuration: configuration, text: "Thermostat - 72\nHeat set to 74", now: now))
        XCTAssertEqual(text, "Thermostat - 72\nHeat set to 75")
        let stale = preview.reconcile(groupID: groupID, actual: "Thermostat - 73\nHeat set to 74", now: now.addingTimeInterval(2))
        XCTAssertEqual(stale.text, "Thermostat - 73\nHeat set to 75")
        XCTAssertTrue(stale.pending)
        let confirmed = preview.reconcile(groupID: groupID, actual: "Thermostat - 73\nHeat set to 75", now: now.addingTimeInterval(3))
        XCTAssertFalse(confirmed.pending)
        XCTAssertEqual(confirmed.text, "Thermostat - 73\nHeat set to 75")
    }
    func testFailureAndTimeoutRestoreAuthoritativeText() throws {
        let (configuration, action, groupID) = fixture()
        let now = Date()
        var preview = DeckThermostatPreview()
        let (ticket, _) = try XCTUnwrap(preview.begin(action: action, configuration: configuration, text: "Thermostat - 72\nHeat set to 74", now: now))
        _ = preview.reconcile(groupID: groupID, actual: "Thermostat - 73\nHeat set to 74", now: now)
        XCTAssertEqual(preview.cancel(ticket), "Thermostat - 73\nHeat set to 74")
        _ = preview.begin(action: action, configuration: configuration, text: "Thermostat - 73\nHeat set to 74", now: now)
        let timedOut = preview.reconcile(groupID: groupID, actual: "Thermostat - 73\nHeat set to 74", now: now.addingTimeInterval(11))
        XCTAssertFalse(timedOut.pending)
        XCTAssertEqual(timedOut.text, "Thermostat - 73\nHeat set to 74")
    }
    func testFractionalAndRepeatedAdjustmentsAccumulateWithoutFloatArtifacts() throws {
        var (configuration, action, groupID) = fixture()
        action.settings["data"] = "{\"increment\":-0.5}"
        var preview = DeckThermostatPreview()
        let (first, text) = try XCTUnwrap(preview.begin(action: action, configuration: configuration, text: "Thermostat - 21°C\nHeat set to 22.5°C"))
        let (_, second) = try XCTUnwrap(preview.begin(action: action, configuration: configuration, text: text))
        XCTAssertEqual(second, "Thermostat - 21°C\nHeat set to 21.5°C")
        XCTAssertNil(preview.cancel(first))
        XCTAssertEqual(preview.reset()[groupID], "Thermostat - 21°C\nHeat set to 22.5°C")
    }
    func testDoesNotGuessForUnsupportedTemplatesRangesOrActions() {
        let (configuration, action, _) = fixture()
        var preview = DeckThermostatPreview()
        for text in ["Custom template 74", "Heat set to 65–75", "Heat set to —"] {
            XCTAssertNil(preview.begin(action: action, configuration: configuration, text: text))
        }
        var invalid = action
        invalid.settings["data"] = "{\"increment\":true}"
        XCTAssertNil(preview.begin(action: invalid, configuration: configuration, text: "Heat set to 74"))
        invalid.settings["data"] = "{\"increment\":1}"
        invalid.settings.removeValue(forKey: "thermostatRole")
        XCTAssertNil(preview.begin(action: invalid, configuration: configuration, text: "Heat set to 74"))
    }
}
