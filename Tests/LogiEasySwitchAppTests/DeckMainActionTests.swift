import XCTest
@testable import LogiEasySwitchApp

final class DeckMainActionTests: XCTestCase {
    func testMainActionIsAKeyboardTargetButNotASubButtonAndSurvivesSync() throws {
        var group = DeckButton()
        group.kind = "group"
        var main = DeckButton()
        main.parentID = group.id
        main.icon = "gamecontroller"
        var secondary = DeckButton()
        secondary.parentID = group.id
        group.settings["mainActionID"] = main.id.uuidString
        var configuration = DeckConfiguration()
        configuration.buttons = [group, main, secondary]
        XCTAssertEqual(DeckGroups.mainAction(group, in: configuration), main)
        XCTAssertEqual(DeckGroups.controls(group, in: configuration).map(\.id), [secondary.id])
        XCTAssertEqual(DeckGroups.activationTargets(in: nil, configuration: configuration).map(\.id), [main.id, secondary.id])
        XCTAssertEqual(DeckGroups.keyPeers(for: main, configuration: configuration).map(\.id), [main.id, secondary.id])
        let shared = DeckSharedConfiguration(configuration)
        try shared.validate()
        let synced = shared.applying(to: DeckConfiguration())
        XCTAssertEqual(DeckGroups.mainAction(synced.buttons[0], in: synced)?.icon, "gamecontroller")
        configuration.buttons.removeAll { $0.id == main.id }
        XCTAssertNil(DeckGroups.mainAction(group, in: configuration))
        XCTAssertEqual(DeckGroups.controls(group, in: configuration).map(\.id), [secondary.id])
    }

    func testMainActionMustBelongToGroup() {
        var group = DeckButton()
        group.kind = "group"
        let unrelated = DeckButton()
        group.settings["mainActionID"] = unrelated.id.uuidString
        var configuration = DeckConfiguration()
        configuration.buttons = [group, unrelated]
        XCTAssertNil(DeckGroups.mainAction(group, in: configuration))
    }
}
