import XCTest
@testable import LogiEasySwitchApp

final class DeckFolderControlsTests: XCTestCase {
    func testFolderControlsAppearBesideFolderAndNotInsideIt() {
        var folder = DeckButton()
        folder.kind = "folder"
        var control = DeckButton()
        control.parentID = folder.id
        control.settings["folderControl"] = "true"
        var inside = DeckButton()
        inside.parentID = folder.id
        var configuration = DeckConfiguration()
        configuration.buttons = [folder, control, inside]
        XCTAssertEqual(DeckGroups.controls(folder, in: configuration).map(\.id), [control.id])
        XCTAssertEqual(DeckGroups.activationTargets(in: nil, configuration: configuration).map(\.id), [folder.id, control.id])
        XCTAssertEqual(DeckGroups.activationTargets(in: folder.id, configuration: configuration).map(\.id), [inside.id])
        XCTAssertEqual(DeckGroups.keyPeers(for: control, configuration: configuration).map(\.id), [folder.id, control.id])
        XCTAssertNil(DeckGroups.containingFolder(of: control, configuration: configuration))
        XCTAssertEqual(DeckGroups.containingFolder(of: inside, configuration: configuration), folder.id)
        control.parentID = nil
        XCTAssertFalse(DeckGroups.isFolderControl(control, in: configuration))
    }

    func testFolderControlNavigationReturnsToScreenItWasOpenedFromAndSyncs() throws {
        var outer = DeckButton()
        outer.kind = "folder"
        var folder = DeckButton()
        folder.kind = "folder"
        folder.parentID = outer.id
        var control = DeckButton()
        control.kind = "folder"
        control.parentID = folder.id
        control.settings["folderControl"] = "true"
        var configuration = DeckConfiguration()
        configuration.buttons = [outer, folder, control]
        XCTAssertEqual(DeckGroups.backDestination(from: control.id, configuration: configuration), outer.id)
        XCTAssertEqual(DeckGroups.containingFolder(of: control, configuration: configuration), outer.id)
        let shared = DeckSharedConfiguration(configuration)
        try shared.validate()
        let synced = shared.applying(to: DeckConfiguration())
        XCTAssertTrue(DeckGroups.isFolderControl(synced.buttons[2], in: synced))
        XCTAssertEqual(DeckGroups.activationTargets(in: outer.id, configuration: synced).map(\.id), [folder.id, control.id])
    }
}
