import AppKit
import SwiftUI
import XCTest
@testable import LogiEasySwitchApp

final class DeckShortcutTreeTests: XCTestCase {
    func testMovesIntoFolderAndBackToRootWithoutLosingSubtree() throws {
        var folder = DeckButton(); folder.kind = "folder"; folder.name = "Folder"
        var nested = DeckButton(); nested.kind = "folder"; nested.name = "Nested"
        var child = DeckButton(); child.parentID = nested.id; child.name = "Child"
        var root = DeckButton(); root.name = "Root"
        let buttons = [folder, nested, child, root]
        let moved = try XCTUnwrap(DeckShortcutTree.moving(nested.id, to: folder.id, at: 0, buttons: buttons))
        XCTAssertEqual(moved.map(\.id), [folder.id, nested.id, child.id, root.id])
        XCTAssertEqual(moved[1].parentID, folder.id)
        XCTAssertEqual(moved[2].parentID, nested.id)
        let restored = try XCTUnwrap(DeckShortcutTree.moving(nested.id, to: nil, at: 0, buttons: moved))
        XCTAssertEqual(restored.map(\.id), [nested.id, child.id, folder.id, root.id])
        XCTAssertNil(restored[0].parentID)
    }
    func testReorderUsesDropIndexBeforeRemovingSource() throws {
        let buttons = [DeckButton(), DeckButton(), DeckButton()]
        let moved = try XCTUnwrap(DeckShortcutTree.moving(buttons[0].id, to: nil, at: 3, buttons: buttons))
        XCTAssertEqual(moved.map(\.id), [buttons[1].id, buttons[2].id, buttons[0].id])
        let reversed = try XCTUnwrap(DeckShortcutTree.moving(buttons[2].id, to: nil, at: 0, buttons: buttons))
        XCTAssertEqual(reversed.map(\.id), [buttons[2].id, buttons[0].id, buttons[1].id])
    }
    func testInvalidDropTargetsAndFolderCyclesAreRejected() {
        var parent = DeckButton(); parent.kind = "folder"
        var child = DeckButton(); child.kind = "folder"; child.parentID = parent.id
        let leaf = DeckButton()
        var groupA = DeckButton(); groupA.kind = "group"
        var groupB = DeckButton(); groupB.kind = "group"
        let buttons = [parent, child, leaf, groupA, groupB]
        XCTAssertFalse(DeckShortcutTree.canMove(parent.id, to: child.id, buttons: buttons))
        XCTAssertFalse(DeckShortcutTree.canMove(parent.id, to: parent.id, buttons: buttons))
        XCTAssertFalse(DeckShortcutTree.canMove(parent.id, to: leaf.id, buttons: buttons))
        XCTAssertFalse(DeckShortcutTree.canMove(groupA.id, to: groupB.id, buttons: buttons))
        XCTAssertTrue(DeckShortcutTree.canMove(leaf.id, to: groupA.id, buttons: buttons))
    }
    @MainActor func testRowsUseConfiguredIconsAndSeparateLocalBadge() throws {
        var group = DeckButton(); group.kind = "group"; group.icon = "thermometer"
        var local = DeckButton(); local.kind = "microphone"; local.icon = "mic.slash"; local.syncWithGroup = false
        let view = DeckShortcutOutline(buttons: .constant([group, local]), selection: .constant(nil), readOnly: false)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        for (index, button) in [group, local].enumerated() {
            let item = try XCTUnwrap(outline.item(atRow: index))
            let cell = try XCTUnwrap(coordinator.outlineView(outline, viewFor: outline.tableColumns.first, item: item) as? NSTableCellView)
            XCTAssertEqual(cell.imageView?.image?.size, NSImage(systemSymbolName: button.icon, accessibilityDescription: nil)?.size)
            let badge = try XCTUnwrap(cell.subviews.first { $0.identifier?.rawValue == "localOnlyBadge" })
            XCTAssertEqual(badge.isHidden, index == 0)
            XCTAssertEqual(badge.constraints.first { $0.identifier == "localBadgeWidth" }?.constant, index == 0 ? 0 : 12)
        }
        XCTAssertEqual(DeckImageIcons.symbol(group), "thermometer")
        var light = DeckButton(); light.kind = "homeassistant"; light.settings["action"] = "light.toggle"
        XCTAssertEqual(DeckImageIcons.symbol(light), "lightbulb")
    }

    @MainActor func testLongNamesWrapAndOutlineStaysWithinViewport() throws {
        var long = DeckButton(); long.name = "Switch Mouse and Keyboard to Another Computer"
        let buttons = [long, DeckButton()]
        let view = DeckShortcutOutline(buttons: .constant(buttons), selection: .constant(long.id), readOnly: false)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        scroll.setFrameSize(NSSize(width: 180, height: 240))
        scroll.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        let item = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertGreaterThan(coordinator.outlineView(outline, heightOfRowByItem: item), 28)
        XCTAssertLessThanOrEqual(outline.frame.width, scroll.contentView.bounds.width + 0.5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(outline.tableColumns.first).width, scroll.contentView.bounds.width)
        let cell = try XCTUnwrap(coordinator.outlineView(outline, viewFor: outline.tableColumns.first, item: item) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.maximumNumberOfLines, 0)
        XCTAssertEqual(cell.textField?.lineBreakMode, .byWordWrapping)
        scroll.setFrameSize(NSSize(width: 140, height: 240))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(outline.frame.width, scroll.contentView.bounds.width + 0.5)
    }

    @MainActor func testOutlineStartsCollapsedAndPreservesExpansionAcrossRefreshes() throws {
        var folder = DeckButton(); folder.kind = "folder"
        var child = DeckButton(); child.parentID = folder.id
        let root = DeckButton()
        var buttons = [folder, child, root]
        var selected: UUID?
        let view = DeckShortcutOutline(buttons: Binding(get: { buttons }, set: { buttons = $0 }), selection: Binding(get: { selected }, set: { selected = $0 }), readOnly: false)
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        XCTAssertEqual(outline.numberOfRows, 2)
        let folderNode = try XCTUnwrap(outline.item(atRow: 0))
        XCTAssertFalse(outline.isItemExpanded(folderNode))
        outline.expandItem(folderNode)
        XCTAssertEqual(outline.numberOfRows, 3)
        buttons[0].name = "Renamed"
        coordinator.refresh(outline, owner: view)
        XCTAssertTrue(outline.isItemExpanded(folderNode))
        outline.collapseItem(folderNode)
        XCTAssertEqual(outline.numberOfRows, 2)
        selected = child.id
        coordinator.refresh(outline, owner: view)
        XCTAssertTrue(outline.isItemExpanded(folderNode))
        XCTAssertEqual(outline.selectedRow, 1)
    }
}
