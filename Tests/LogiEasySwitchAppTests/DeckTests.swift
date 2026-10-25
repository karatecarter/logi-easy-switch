import XCTest
@testable import LogiEasySwitchApp

final class DeckTests: XCTestCase {
    func testHomeAssistantConnectionUsesAuthenticatedReadOnlyEndpoint() async throws {
        var configuration = DeckConfiguration()
        configuration.homeAssistantURL = " https://home.example.com/prefix/ "
        try await DeckHomeAssistantClient.testConnection(configuration, token: "test-token") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://home.example.com/prefix/api/")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return Data(#"{"message":"API running."}"#.utf8)
        }
    }

    func testHomeAssistantConnectionRejectsUnrelatedServerResponse() async {
        var configuration = DeckConfiguration()
        configuration.homeAssistantURL = "https://home.example.com"
        do {
            try await DeckHomeAssistantClient.testConnection(configuration, token: "test-token") { _ in Data("<html>Login</html>".utf8) }
            XCTFail("A website response must not count as a successful HA connection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API status")) }
    }

    func testHomeAssistantConnectionValidationBeforeNetwork() async {
        for (address, token) in [("file:///tmp/test", "token"), ("https://home.example.com", "")] {
            var configuration = DeckConfiguration()
            configuration.homeAssistantURL = address
            do {
                try await DeckHomeAssistantClient.testConnection(configuration, token: token) { _ in
                    XCTFail("Invalid configuration must fail before transport")
                    return Data()
                }
                XCTFail("Expected validation failure")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testHomeAssistantHTTPFailuresHaveActionableMessages() throws {
        let url = try XCTUnwrap(URL(string: "https://home.example.com/api/"))
        for (status, message) in [(401, "access token"), (403, "permissions"), (302, "redirect"), (404, "base URL")] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            XCTAssertThrowsError(try DeckHomeAssistantClient.validateResponse(response)) { error in
                XCTAssertTrue(error.localizedDescription.contains(message))
            }
        }
    }

    func testServiceDataRejectsSmartQuotesWithHelpfulError() {
        XCTAssertThrowsError(try DeckHomeAssistantClient.actionData("{“entity_id”:“light.office_lights”}")) { error in
            XCTAssertTrue(error.localizedDescription.contains("curly quotes"))
        }
        for invalid in ["[]", "{", "{'entity_id':'light.office'}"] {
            XCTAssertThrowsError(try DeckHomeAssistantClient.actionData(invalid)) { error in
                XCTAssertTrue(error.localizedDescription.contains("JSON"))
            }
        }
    }

    func testValidServiceDataPreservesUnicodeText() throws {
        let source = #"{"entity_id":"light.office_lights","message":"Say “hello”"}"#
        XCTAssertEqual(try DeckHomeAssistantClient.actionData(source), Data(source.utf8))
    }

    func testActionCatalogReadsNamesFiltersAndResponseRequirements() throws {
        let source = Data(#"[{"domain":"light","services":{"toggle":{"name":"Toggle lights","target":{"entity":[{"domain":["light"]}]}}}},{"domain":"weather","services":{"get_forecasts":{"response":{"optional":false}}}},{"domain":"script","services":{"example":{}}}]"#.utf8)
        let actions = try DeckHACatalog.parseActions(source)
        XCTAssertEqual(actions.map(\.id), ["light.toggle", "script.example", "weather.get_forecasts"])
        XCTAssertEqual(actions[0].name, "Toggle lights")
        XCTAssertEqual(actions[0].domains, ["light"])
        XCTAssertFalse(actions[0].responseRequired)
        XCTAssertTrue(actions[2].responseRequired)
        let entities = try JSONDecoder().decode([DeckHAEntity].self, from: Data(#"[{"entity_id":"light.office","state":"on","attributes":{"friendly_name":"Office lights"}},{"entity_id":"switch.office","state":"off","attributes":{}}]"#.utf8))
        let catalog = DeckHACatalog(actions: actions, entities: entities)
        XCTAssertEqual(catalog.entities(for: "light.toggle").map(\.id), ["light.office"])
        XCTAssertEqual(catalog.entities(for: "script.example").count, 2)
    }

    func testEntitySelectionBuildsJSONAndPreservesExtraParameters() throws {
        let source = #"{"entity_id":["light.old"],"brightness_pct":45,"transition":2}"#
        let selected = try DeckHATarget.selecting("light.office", in: source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(selected.utf8)) as? [String: Any])
        XCTAssertEqual(object["entity_id"] as? String, "light.office")
        XCTAssertEqual(object["brightness_pct"] as? Int, 45)
        let removed = try DeckHATarget.selecting("", in: selected)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(removed.utf8)) as? [String: Any])
        XCTAssertNil(result["entity_id"])
        XCTAssertEqual(result["transition"] as? Int, 2)
        XCTAssertThrowsError(try DeckHATarget.selecting("light.office", in: "invalid"))
    }

    func testExistingLightButtonsAutomaticallyUseStateUnlessOverridden() {
        var button = DeckButton()
        button.kind = "homeassistant"
        button.settings = ["action":"light.toggle", "data": #"{"entity_id":"light.office"}"#]
        XCTAssertTrue(DeckHATarget.automaticLight(button))
        XCTAssertEqual(DeckHATarget.entities(button), ["light.office"])
        button.settings["automaticLightIcon"] = "false"
        XCTAssertFalse(DeckHATarget.automaticLight(button))
        button.settings["automaticLightIcon"] = "true"
        button.settings["iconTemplate"] = "custom"
        XCTAssertFalse(DeckHATarget.automaticLight(button))
    }

    func testLightPresentationDoesNotClaimUnavailableLightsAreOff() {
        let on = DeckHATarget.lightPresentation(states: ["on", "off"])
        XCTAssertEqual(on.icon, "lightbulb.fill")
        XCTAssertEqual(on.highlighted, true)
        let off = DeckHATarget.lightPresentation(states: ["off", "off"])
        XCTAssertEqual(off.icon, "lightbulb")
        XCTAssertEqual(off.highlighted, false)
        XCTAssertEqual(DeckHATarget.lightPresentation(states: ["unavailable"]).text, "Unavailable")
        XCTAssertEqual(DeckHATarget.lightPresentation(states: []).text, "Unavailable")
    }

    func testThermostatPresetHasIndependentAdjustmentAndModeActions() throws {
        let buttons = DeckThermostatPreset.make()
        let group = try XCTUnwrap(buttons.first)
        var configuration = DeckConfiguration()
        configuration.buttons = buttons
        let controls = DeckGroups.controls(group, in: configuration)
        XCTAssertEqual(controls.map(\.name), ["+", "−", "Mode"])
        XCTAssertEqual(controls[0].settings["action"], "script.adjust_thermostat")
        for (index, increment) in [(0, 1), (1, -1)] {
            let data = try DeckHomeAssistantClient.actionData(DeckTicks.resolved(controls[index], ticks: 1).settings["data"]!)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["increment"] as? Int, increment)
            XCTAssertEqual(controls[index].dismiss, .never)
        }
        XCTAssertEqual(controls[2].kind, "folder")
        XCTAssertEqual(configuration.buttons.filter { $0.parentID == controls[2].id }.map(\.name), ["Cool", "Heat", "Auto", "Off"])
    }

    func testThermostatSelectionUpdatesModeTargetsAndTemplateWithoutChangingIncrements() throws {
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        let group = try XCTUnwrap(configuration.buttons.first)
        try DeckThermostatPreset.configure(groupID: group.id, entity: "climate.office", script: "script.adjust_office", configuration: &configuration)
        let updated = try XCTUnwrap(configuration.buttons.first)
        let template = try XCTUnwrap(updated.settings["textTemplate"])
        XCTAssertTrue(template.contains("current_temperature"))
        XCTAssertTrue(template.contains("Thermostat -"))
        XCTAssertTrue(template.contains("\n"))
        XCTAssertTrue(template.contains("set to"))
        XCTAssertTrue(template.contains("target_temp_low"))
        for button in configuration.buttons where button.settings["thermostatRole"] == "mode" {
            XCTAssertEqual(DeckHATarget.entities(button), ["climate.office"])
            XCTAssertNil(button.settings["requiresThermostat"])
        }
        let controls = DeckGroups.controls(updated, in: configuration)
        XCTAssertEqual(controls[0].settings["action"], "script.adjust_office")
        XCTAssertEqual(controls[1].settings["action"], "script.adjust_office")
        XCTAssertEqual(controls[0].settings["data"], "{\"increment\":\"ticks\"}")
        XCTAssertEqual(controls[1].settings["data"], "{\"increment\":\"-ticks\"}")
        let decoded = try JSONDecoder().decode(DeckConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertThrowsError(try DeckThermostatPreset.configure(groupID: group.id, entity: "climate.bad'input", configuration: &configuration))
    }

    func testGroupKeysShareTheVisibleFolderAndBackSkipsTheGroup() throws {
        var configuration = DeckConfiguration()
        var outer = DeckButton()
        outer.kind = "folder"
        configuration.buttons = [outer] + DeckThermostatPreset.make(parentID: outer.id)
        let group = configuration.buttons[1]
        let controls = DeckGroups.controls(group, in: configuration)
        let mode = try XCTUnwrap(controls.first { $0.kind == "folder" })
        let targets = DeckGroups.activationTargets(in: outer.id, configuration: configuration)
        XCTAssertEqual(targets.map(\.id), controls.map(\.id))
        XCTAssertFalse(targets.contains { $0.settings["thermostatRole"] == "mode" })
        XCTAssertEqual(DeckGroups.backDestination(from: mode.id, configuration: configuration), outer.id)
        XCTAssertEqual(DeckGroups.activationTargets(in: mode.id, configuration: configuration).count, 4)
        XCTAssertEqual(DeckGroups.keyPeers(for: controls[0], configuration: configuration).map(\.id), targets.map(\.id))
        XCTAssertEqual(DeckGroups.backDestination(from: outer.id, configuration: configuration), nil)
    }

    func testUnconfiguredThermostatModeFailsBeforeNetwork() async throws {
        let mode = try XCTUnwrap(DeckThermostatPreset.make().first { $0.settings["thermostatRole"] == "mode" })
        do {
            try await BuiltinDeckProvider().execute(mode, configuration: DeckConfiguration())
            XCTFail("Missing thermostat target must not call an untargeted service")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Choose a thermostat")) }
    }

    func testOpeningDismissalPreservesLegacySettingsAndIndependentCheckbox() throws {
        var configuration = DeckConfiguration()
        XCTAssertFalse(configuration.openingDismissEnabled)
        configuration.idleTimeout = 8
        XCTAssertTrue(configuration.openingDismissEnabled)
        configuration.openingDismissEnabled = false
        XCTAssertEqual(configuration.idleTimeout, 8)
        let decoded = try JSONDecoder().decode(DeckConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertFalse(decoded.openingDismissEnabled)
        XCTAssertEqual(decoded.idleTimeout, 8)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        legacy.removeValue(forKey: "dismissAfterOpening")
        let migrated = try JSONDecoder().decode(DeckConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(migrated.openingDismissEnabled)
    }

    func testReturnDestinationDefaultsToBackAndCanTargetAnyFolder() throws {
        var outer = DeckButton()
        outer.kind = "folder"
        outer.name = "Outer"
        var inner = DeckButton()
        inner.kind = "folder"
        inner.parentID = outer.id
        inner.name = "Inner"
        var elsewhere = DeckButton()
        elsewhere.kind = "folder"
        var action = DeckButton()
        action.parentID = inner.id
        action.returnAfterAction = DeckReturnBehavior(enabled: true, delay: 2)
        var configuration = DeckConfiguration()
        configuration.buttons = [outer, inner, elsewhere, action]
        XCTAssertEqual(DeckGroups.returnDestination(for: action, configuration: configuration), outer.id)
        action.returnAfterAction?.useParent = false
        action.returnAfterAction?.folderID = elsewhere.id
        XCTAssertEqual(DeckGroups.returnDestination(for: action, configuration: configuration), elsewhere.id)
        action.returnAfterAction?.folderID = nil
        XCTAssertNil(DeckGroups.returnDestination(for: action, configuration: configuration))
        action.returnAfterAction?.folderID = UUID()
        XCTAssertEqual(DeckGroups.returnDestination(for: action, configuration: configuration), outer.id)
        XCTAssertEqual(DeckGroups.folderLabel(inner, configuration: configuration), "Outer / Inner")
    }

    func testThermostatModeReturnSkipsItsMultiActionOwner() throws {
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        var action = try XCTUnwrap(configuration.buttons.first { $0.settings["thermostatRole"] == "mode" })
        action.returnAfterAction = DeckReturnBehavior(enabled: true, delay: 1)
        XCTAssertNotNil(DeckGroups.containingFolder(of: action, configuration: configuration))
        XCTAssertNil(DeckGroups.returnDestination(for: action, configuration: configuration))
        let groupControl = configuration.buttons[1]
        XCTAssertNil(DeckGroups.containingFolder(of: groupControl, configuration: configuration))
    }

    func testReturnRulePersistsAndLegacyButtonsRemainReadable() throws {
        var button = DeckButton()
        button.returnAfterAction = DeckReturnBehavior(enabled: true, useParent: false, folderID: UUID(), delay: 3)
        let data = try JSONEncoder().encode(button)
        XCTAssertEqual(try JSONDecoder().decode(DeckButton.self, from: data), button)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "returnAfterAction")
        let decoded = try JSONDecoder().decode(DeckButton.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.returnAfterAction)
    }

    func testCountdownTracksDeadlineAndClampsProgress() {
        let now = ContinuousClock.now
        let countdown = DeckCountdown(title: "Return to Mode", seconds: 5, now: now)
        XCTAssertEqual(countdown.remaining(at: now), 5, accuracy: 0.001)
        XCTAssertEqual(countdown.fractionRemaining(at: now.advanced(by: .seconds(2))), 0.6, accuracy: 0.001)
        XCTAssertEqual(countdown.remaining(at: now.advanced(by: .seconds(9))), 0)
        XCTAssertEqual(countdown.fractionRemaining(at: now.advanced(by: .seconds(-1))), 1)
        for seconds in [0.0, -5, Double.nan, Double.infinity] {
            let immediate = DeckCountdown(title: "Auto-dismiss", seconds: seconds, now: now)
            XCTAssertEqual(immediate.remaining(at: now), 0)
            XCTAssertEqual(immediate.fractionRemaining(at: now), 0)
        }
    }

    func testDismissalOverrides() {
        XCTAssertEqual(DeckDismiss.inherit.delay(defaultEnabled: true, defaultDelay: 2, override: 9), 2)
        XCTAssertNil(DeckDismiss.inherit.delay(defaultEnabled: false, defaultDelay: 2, override: 9))
        XCTAssertEqual(DeckDismiss.always.delay(defaultEnabled: false, defaultDelay: 2, override: 3), 3)
        XCTAssertEqual(DeckDismiss.always.delay(defaultEnabled: true, defaultDelay: 2, override: -1), 0)
        XCTAssertNil(DeckDismiss.never.delay(defaultEnabled: true, defaultDelay: 2, override: 0))
    }

    func testConfigurationPreservesHierarchyAndProviderSettings() throws {
        var configuration = DeckConfiguration()
        var folder = DeckButton()
        folder.kind = "folder"
        var action = DeckButton()
        action.parentID = folder.id
        action.kind = "future.streamdeck"
        action.settings = ["actionUUID": "com.example.mute", "settings": #"{"device":"input"}"#]
        action.key = Shortcut(keyCode: 83, modifiers: 0, label: "Numpad 1")
        action.dismiss = .never
        configuration.buttons = [folder, action]
        let decoded = try JSONDecoder().decode(DeckConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertNotEqual(decoded.buttons[1].key?.keyCode, 18) // Top-row 1 remains distinct.
    }

    func testProcessArgumentsAreNotShellExpanded() async throws {
        let result = try await process("/usr/bin/printf", ["%s", "$(echo unsafe); `echo unsafe`"])
        XCTAssertEqual(result, "$(echo unsafe); `echo unsafe`")
    }

    func testProcessFailureIsReported() async {
        do {
            _ = try await process("/usr/bin/false", [])
            XCTFail("Expected a failing process to throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("failed")) }
    }

    func testUnconfiguredCameraCannotReportSuccess() async {
        var button = DeckButton()
        button.kind = "camera"
        do {
            try await BuiltinDeckProvider().execute(button, configuration: DeckConfiguration())
            XCTFail("Expected missing command error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Configure")) }
    }

    func testInvalidHomeAssistantActionRejectedBeforeNetwork() async {
        var button = DeckButton()
        button.kind = "homeassistant"
        button.settings = ["action": "light/../../toggle"]
        do {
            try await BuiltinDeckProvider().execute(button, configuration: DeckConfiguration())
            XCTFail("Expected validation error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("action")) }
    }
}
