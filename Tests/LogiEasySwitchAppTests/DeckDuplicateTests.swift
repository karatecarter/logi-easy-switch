import XCTest
@testable import LogiEasySwitchApp

final class DeckDuplicateTests: XCTestCase {
    func testDuplicateActionPreservesConfigurationAndClearsConflictingKey() throws {
        var action = DeckButton()
        action.parentID = UUID()
        action.name = "Launch"
        action.key = Shortcut(keyCode: 1, modifiers: 0, label: "S")
        action.settings = ["filePath": "/tmp/example", "iconSource": "image", "iconImage": "example"]
        action.syncWithGroup = false
        let result = try XCTUnwrap(DeckShortcutTree.duplicating(action.id, buttons: [action]))
        let copy = result.buttons[1]
        XCTAssertEqual(result.buttons[0], action)
        XCTAssertEqual(copy.id, result.selection)
        XCTAssertNotEqual(copy.id, action.id)
        XCTAssertEqual(copy.name, "Launch Copy")
        XCTAssertEqual(copy.parentID, action.parentID)
        XCTAssertEqual(copy.settings, action.settings)
        XCTAssertEqual(copy.syncWithGroup, false)
        XCTAssertNil(copy.key)
    }

    func testDuplicateContainerRemapsChildrenMainActionAndInternalReturnTarget() throws {
        var group = DeckButton(); group.kind = "group"
        var folder = DeckButton(); folder.kind = "folder"; folder.parentID = group.id
        var action = DeckButton(); action.parentID = folder.id
        action.returnAfterAction = DeckReturnBehavior(enabled: true, useParent: false, folderID: folder.id, delay: 2)
        group.settings["mainActionID"] = folder.id.uuidString
        let originals = [group, folder, action]
        let result = try XCTUnwrap(DeckShortcutTree.duplicating(group.id, buttons: originals))
        let copies = Array(result.buttons.suffix(3))
        XCTAssertEqual(Array(result.buttons.prefix(3)), originals)
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: originals.map(\.id)))
        XCTAssertEqual(copies[1].parentID, copies[0].id)
        XCTAssertEqual(copies[2].parentID, copies[1].id)
        XCTAssertEqual(copies[0].settings["mainActionID"], copies[1].id.uuidString)
        XCTAssertEqual(copies[2].returnAfterAction?.folderID, copies[1].id)
        XCTAssertNil(DeckShortcutTree.duplicating(UUID(), buttons: originals))
    }
}
