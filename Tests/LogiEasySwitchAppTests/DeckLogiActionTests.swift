import XCTest
@testable import LogiEasySwitchApp

final class DeckLogiActionTests: XCTestCase {
    func testNewButtonsDefaultToOpenFileAndExistingMicrophoneButtonsKeepTheirType() throws {
        XCTAssertEqual(DeckButton().kind, "application")
        var old = DeckButton(); old.kind = "microphone"
        XCTAssertEqual(try JSONDecoder().decode(DeckButton.self, from: JSONEncoder().encode(old)).kind, "microphone")
    }
    func testLogiRequestDefaultsToBothAndValidatesDestinationAndScope() throws {
        var button = DeckButton()
        button.kind = "logi"
        XCTAssertThrowsError(try DeckLogiRequest.from(button))
        button.settings["destination"] = "Mac Mini"
        XCTAssertEqual(try DeckLogiRequest.from(button).devices, .both)
        button.settings["devices"] = "keyboard"
        XCTAssertEqual(try DeckLogiRequest.from(button).devices, .keyboard)
        button.settings["devices"] = "invalid"
        XCTAssertThrowsError(try DeckLogiRequest.from(button))
    }
    func testScopedNetworkCommandsRejectRetainedUnknownTargetsAndBadScopes() throws {
        let request = DeckLogiRequest(target: "Mac Mini", devices: .mouse)
        let payload = try JSONEncoder().encode(request)
        XCTAssertEqual(DeckLogiRequest.accepted(payload: payload, retained: false, targets: ["Mac Mini"]), request)
        XCTAssertNil(DeckLogiRequest.accepted(payload: payload, retained: true, targets: ["Mac Mini"]))
        XCTAssertNil(DeckLogiRequest.accepted(payload: payload, retained: false, targets: ["Other Mac"]))
        XCTAssertNil(DeckLogiRequest.accepted(payload: Data(#"{"target":"Mac Mini","devices":"invalid"}"#.utf8), retained: false, targets: ["Mac Mini"]))
    }
    func testScopeSelectsOnlyRequestedDeviceTypes() {
        let mouse = LogiDevice(id: "m", name: "Mouse", type: "MOUSE", state: "ACTIVE", connected: true)
        let keyboard = LogiDevice(id: "k", name: "Keyboard", type: "KEYBOARD", state: "ACTIVE", connected: true)
        XCTAssertTrue(DeckLogiScope.both.includes(mouse))
        XCTAssertTrue(DeckLogiScope.both.includes(keyboard))
        XCTAssertFalse(DeckLogiScope.keyboard.includes(mouse))
        XCTAssertFalse(DeckLogiScope.mouse.includes(keyboard))
    }
    @MainActor func testProviderPassesRequestedScopeWithoutTouchingHardware() async throws {
        let service = DeckLogiService()
        var received: DeckLogiRequest?
        service.perform = { received = $0 }
        var button = DeckButton()
        button.kind = "logi"
        button.settings = ["destination": "Mini", "devices": "keyboard"]
        try await DeckLogiProvider(service: service).execute(button, configuration: DeckConfiguration())
        XCTAssertEqual(received, DeckLogiRequest(target: "Mini", devices: .keyboard))
    }
}
