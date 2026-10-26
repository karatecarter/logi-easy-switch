import AppKit
import SwiftUI
import XCTest
@testable import LogiEasySwitchApp

final class DeckWindowLayoutTests: XCTestCase {
    func testHeightGrowsBeforeWidthAndAlwaysCentersOnSelectedScreen() {
        let screen = CGRect(x: 1440, y: -200, width: 1440, height: 900)
        let fit = DeckWindowLayout.fit(in: screen) { _, width in
            XCTAssertEqual(width, 620)
            return 700
        }
        XCTAssertEqual(fit.columns, 3)
        XCTAssertEqual(fit.frame.width, 620)
        XCTAssertEqual(fit.frame.height, 700)
        XCTAssertEqual(fit.frame.midX, screen.midX)
        XCTAssertEqual(fit.frame.midY, screen.midY)
    }
    func testWidthGrowsOnlyWhenHeightDoesNotFit() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let fit = DeckWindowLayout.fit(in: screen) { columns, _ in
            columns == 3 ? 1200 : columns == 4 ? 900 : 600
        }
        XCTAssertEqual(fit.columns, 5)
        XCTAssertGreaterThan(fit.frame.width, 620)
        XCTAssertEqual(fit.frame.height, 600)
        XCTAssertTrue(screen.contains(fit.frame))
        XCTAssertEqual(fit.frame.midX, screen.midX)
        XCTAssertEqual(fit.frame.midY, screen.midY)
    }
    func testHugeCollectionsRemainWithinScreenAndSmallFoldersShrink() {
        let screen = CGRect(x: -1000, y: 50, width: 1000, height: 700)
        let huge = DeckWindowLayout.fit(in: screen) { _, _ in 10000 }
        XCTAssertTrue(screen.contains(huge.frame))
        let small = DeckWindowLayout.fit(in: screen) { _, _ in 180 }
        XCTAssertEqual(small.columns, 3)
        XCTAssertLessThan(small.frame.width, huge.frame.width)
        XCTAssertLessThan(small.frame.height, huge.frame.height)
    }
    @MainActor func testMixedTilesHaveSameHeightAndWindowIncludesLastRow() throws {
        let name = "DeckWindowLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        let controller = DeckController(store: store)
        var thermostat = DeckThermostatPreset.make()
        let group = thermostat[0]
        thermostat[0].settings["textReplacesName"] = "true"
        var mainGroup = DeckButton(); mainGroup.kind = "group"
        var main = DeckButton(); main.parentID = mainGroup.id
        main.settings["iconSource"] = "application"
        var control = DeckButton(); control.parentID = mainGroup.id
        mainGroup.settings["mainActionID"] = main.id.uuidString
        var folder = DeckButton(); folder.kind = "folder"
        var folderControl = DeckButton(); folderControl.parentID = folder.id
        folderControl.settings["folderControl"] = "true"
        store.configuration.buttons = [DeckButton(), DeckButton(), DeckButton(), mainGroup, main, control, folder, folderControl] + thermostat
        controller.presentations[group.id] = DeckPresentation(text: "Thermostat - 69\nHeat set to 68")
        func measure() -> CGFloat {
            let view = NSHostingView(rootView: DeckView(controller: controller, store: store, measuringColumns: 3).frame(width: 620).fixedSize(horizontal: false, vertical: true))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        XCTAssertEqual(controller.visibleButtons.count, 6)
        XCTAssertEqual(measure(), DeckWindowLayout.contentHeight(buttonCount: 6, columns: 3), accuracy: 1)
        store.configuration.buttons.append(DeckButton())
        let expected = DeckWindowLayout.contentHeight(buttonCount: 7, columns: 3)
        XCTAssertEqual(measure(), expected, accuracy: 1)
        let fit = DeckWindowLayout.fit(in: CGRect(x: 0, y: 0, width: 1400, height: 900)) { columns, _ in
            DeckWindowLayout.contentHeight(buttonCount: controller.visibleButtons.count, columns: columns)
        }
        XCTAssertEqual(fit.frame.height, expected)
        XCTAssertEqual(fit.columns, 3)
    }
    @MainActor func testMeasurementIncludesEveryGridRowWithoutScrolling() throws {
        let name = "DeckWindowLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeckStore(defaults: defaults)
        let controller = DeckController(store: store)
        func measure(_ count: Int, realIcons: Bool = false) -> CGFloat {
            store.configuration.buttons = (0..<count).map { _ in
                var button = DeckButton()
                if realIcons { button.settings["iconSource"] = "image" }
                return button
            }
            let view = NSHostingView(rootView: DeckView(controller: controller, store: store, measuringColumns: 3).frame(width: 620).fixedSize(horizontal: false, vertical: true))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        let oneRow = measure(3)
        let threeRows = measure(9)
        XCTAssertGreaterThan(oneRow, 150)
        XCTAssertGreaterThan(threeRows, oneRow + 200)
        XCTAssertEqual(measure(3, realIcons: true), oneRow, accuracy: 1, "Real icons must not make ordinary tiles taller")
    }
}
