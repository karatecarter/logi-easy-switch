import XCTest
@testable import LogiEasySwitchApp

final class DeckTicksTests: XCTestCase {
    func testPayloadSendsSignedTapCountAndPreservesOtherFields() throws {
        let controls = DeckThermostatPreset.make()
        for (button, expected) in [(controls[1], 4), (controls[2], -4)] {
            var input = button
            let sign = try XCTUnwrap(DeckTicks.sign(button))
            input.settings["data"] = sign > 0 ? #"{"increment":"ticks","extra":42}"# : #"{"increment":"-ticks","extra":42}"#
            let resolved = try DeckTicks.resolved(input, ticks: 4)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resolved.settings["data"]!.utf8)) as? [String: Any])
            XCTAssertEqual(object["increment"] as? Int, expected)
            XCTAssertEqual(object["extra"] as? Int, 42)
        }
    }
    func testExistingNumericPresetMigratesToTicks() throws {
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        configuration.buttons[1].settings["data"] = #"{"increment":1}"#
        configuration.buttons[2].settings["data"] = #"{"increment":-2}"#
        let migrated = configuration.migratingThermostatTicks()
        XCTAssertEqual(DeckTicks.sign(migrated.buttons[1]), 1)
        XCTAssertEqual(DeckTicks.sign(migrated.buttons[2]), -1)
        XCTAssertEqual(migrated.migratingThermostatTicks(), migrated)
    }
    @MainActor func testRapidTapsProduceOneFlushAfterLastTap() async throws {
        let debouncer = DeckTickDebouncer(delay: .milliseconds(100))
        let id = UUID()
        var sends: [Int] = []
        for count in 1...3 {
            debouncer.schedule(id) { sends.append(count) }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(sends.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sends, [3])
    }
    @MainActor func testMixedThermostatTapsSendOneNetIncrementAfterQuietPeriod() async throws {
        let debouncer = DeckTickDebouncer(delay: .milliseconds(100))
        var configuration = DeckConfiguration()
        configuration.buttons = DeckThermostatPreset.make()
        let plus = configuration.buttons[1]
        let minus = configuration.buttons[2]
        XCTAssertEqual(DeckTicks.batchID(plus, configuration: configuration), DeckTicks.batchID(minus, configuration: configuration))
        var increment = 0
        var sends: [Int] = []
        for button in [minus, plus, plus, minus, minus] {
            increment += try XCTUnwrap(DeckTicks.sign(button))
            let total = increment
            debouncer.schedule(DeckTicks.batchID(button, configuration: configuration)) {
                let resolved = try! DeckTicks.resolvedIncrement(button, increment: total)
                let body = try! JSONSerialization.jsonObject(with: Data(resolved.settings["data"]!.utf8)) as! [String: Any]
                sends.append(body["increment"] as! Int)
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(sends.isEmpty)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(sends, [-1])
        let resolved = try DeckTicks.resolvedIncrement(minus, increment: 0)
        let body = try JSONSerialization.jsonObject(with: Data(resolved.settings["data"]!.utf8)) as! [String: Any]
        XCTAssertEqual(body["increment"] as? Int, 0)
        let other = DeckThermostatPreset.make()
        XCTAssertNotEqual(DeckTicks.batchID(other[1], configuration: DeckConfiguration()), DeckTicks.batchID(plus, configuration: configuration))
    }
}
