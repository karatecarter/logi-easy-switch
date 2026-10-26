import XCTest
@testable import LogiEasySwitchApp

final class SecurityReviewProofTests: XCTestCase {
    @MainActor func testSyncedCameraStateScriptRunsWithoutActionActivation() async throws {
        let suite = "security-review-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeckStore(defaults: defaults)
        let sync = DeckSyncCoordinator(store: store, defaults: defaults, backup: { _ in })
        let publisher = UUID().uuidString.lowercased()
        sync.settings = DeckSyncSettings(role: .follower, source: publisher)
        var remote = DeckConfiguration()
        var button = DeckButton()
        button.kind = "camera"
        // Harmless proof: evaluate and return a literal, without any shell,
        // network requests, automation targets, or external file modification.
        button.settings["stateScript"] = "return \"security-review-proof\""
        remote.buttons = [button]
        let envelope = DeckSyncEnvelope(source: publisher, revision: 1, configuration: DeckSharedConfiguration(remote))
        sync.receive(try JSONEncoder().encode(envelope))
        XCTAssertEqual(store.configuration.buttons.count, 1)
        let presentation = try await BuiltinDeckProvider().presentation(store.configuration.buttons[0], configuration: store.configuration)
        XCTAssertEqual(presentation.text, "security-review-proof")
        sync.stop()
    }

    func testHTTPHomeAssistantRequestCarriesBearerCredential() throws {
        var configuration = DeckConfiguration()
        configuration.homeAssistantURL = "http://homeassistant.local:8123"
        let request = try DeckHomeAssistantClient.makeRequest(configuration, token: "security-review-dummy")
        XCTAssertEqual(request.url?.scheme, "http")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer security-review-dummy")
    }

    func testProcessWritesMoreThanOutputReadCap() async throws {
        // The child asserts the actual file is larger than the claimed output
        // cap. Only dummy bytes are written, and process() removes its own file.
        let program = "import sys,os; sys.stdout.buffer.write(b'x'*1048576); sys.stdout.flush(); assert os.fstat(1).st_size == 1048576"
        let result = try await process("/usr/bin/python3", ["-c", program])
        XCTAssertEqual(result.utf8.count, 65536)
    }
}
