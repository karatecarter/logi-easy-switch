import XCTest
import Carbon.HIToolbox
@testable import LogiEasySwitchApp

final class ShortcutLabelTests: XCTestCase {
    func testSavedNumpadEnterHasVisibleLabel() {
        let key = Shortcut(keyCode: 76, modifiers: 0, label: "Numpad \u{3}")
        XCTAssertEqual(key.displayLabel, "Numpad Enter")
        XCTAssertEqual(key.compactDisplayLabel, "Enter")
    }

    func testCompactNumpadLabelsKeepModifiers() {
        let key = Shortcut(keyCode: 83, modifiers: UInt32(cmdKey), label: "Numpad 1")
        XCTAssertEqual(key.displayLabel, "⌘Numpad 1")
        XCTAssertEqual(key.compactDisplayLabel, "⌘1")
        XCTAssertEqual(Shortcut(keyCode: 69, modifiers: 0, label: "+").compactDisplayLabel, "+")
        XCTAssertEqual(Shortcut(keyCode: 0, modifiers: 0, label: "A").compactDisplayLabel, "A")
    }
}
