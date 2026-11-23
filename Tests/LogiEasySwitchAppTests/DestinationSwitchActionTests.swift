import XCTest
@testable import LogiEasySwitchApp

final class DestinationSwitchActionTests: XCTestCase {
    func testDefaultsAndWhitespaceDoNothing() async throws {
        XCTAssertTrue(DestinationSwitchAction().isEmpty)
        XCTAssertTrue(DestinationSwitchAction(kind: .command, command: " \n ").isEmpty)
        XCTAssertTrue(DestinationSwitchAction(kind: .application, applicationPath: " ").isEmpty)
        try await DestinationSwitchAction().execute()
    }

    func testActionRoundTripsWithoutHardcodedDefaults() throws {
        let command = "'/Applications/CRG9 Control.app/Contents/MacOS/crg9-control' input dp2 --json --display H1AK500000"
        let actions = ["MHK": DestinationSwitchAction(kind: .command, command: command)]
        let restored = try JSONDecoder().decode([String: DestinationSwitchAction].self, from: JSONEncoder().encode(actions))
        XCTAssertEqual(restored, actions)
        XCTAssertNil(restored["macmini"])
    }

    func testCommandSupportsQuotedPathsAndReportsFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("file with spaces.txt")
        let action = DestinationSwitchAction(kind: .command, command: "/usr/bin/printf '%s' 'test value' > '\(file.path)'")
        try await action.execute()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "test value")
        do {
            try await DestinationSwitchAction(kind: .command, command: "printf 'expected failure' >&2; exit 3").execute()
            XCTFail("Nonzero command exit must be surfaced")
        } catch { XCTAssertTrue(error.localizedDescription.contains("expected failure")) }
    }

    func testAppRequiresExistingAbsoluteAppPath() throws {
        for path in ["Safari", "https://example.com/app", "/no-such-app-\(UUID()).app", "/bin/sh"] {
            XCTAssertThrowsError(try DestinationSwitchAction(kind: .application, applicationPath: path).applicationURL())
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try DestinationSwitchAction(kind: .application, applicationPath: folder.path).applicationURL().path, folder.path)
    }

    func testPairRunsOneActionAfterSwitch() async throws {
        var events: [String] = []
        try await DestinationSwitchFlow.perform(pendingCount: 2, switchDevices: { events.append("switch pair") }, followUp: { events.append("action") })
        XCTAssertEqual(events, ["switch pair", "action"])
    }

    func testLocalNoopSkipsActionButNetworkRequestStillRunsIt() async throws {
        var count = 0
        try await DestinationSwitchFlow.perform(pendingCount: 0, switchDevices: {}, followUp: { count += 1 })
        XCTAssertEqual(count, 0)
        try await DestinationSwitchFlow.perform(pendingCount: 0, networkRequest: true, switchDevices: {}, followUp: { count += 1 })
        XCTAssertEqual(count, 1)
    }

    func testSwitchFailureDoesNotRunAction() async {
        var didRun = false
        do {
            try await DestinationSwitchFlow.perform(pendingCount: 1, switchDevices: { throw DeckError.message("switch failed") }, followUp: { didRun = true })
            XCTFail("Expected switch failure")
        } catch { XCTAssertFalse(didRun) }
    }

    func testFollowUpFailureDoesNotRepeatPeripheralSwitch() async {
        var switchCount = 0
        do {
            try await DestinationSwitchFlow.perform(pendingCount: 1, switchDevices: { switchCount += 1 }, followUp: { throw DeckError.message("command failed") })
            XCTFail("Expected action failure")
        } catch { XCTAssertEqual(switchCount, 1) }
    }

    func testRunnerContinuesAfterAnActionFails() async throws {
        let runner = DestinationActionRunner()
        do { try await runner.run(DestinationSwitchAction(kind: .command, command: "exit 7")); XCTFail("Expected failure") } catch {}
        try await runner.run(DestinationSwitchAction(kind: .command, command: "/usr/bin/true"))
    }
}
