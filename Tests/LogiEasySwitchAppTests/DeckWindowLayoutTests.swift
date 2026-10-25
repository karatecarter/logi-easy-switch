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
