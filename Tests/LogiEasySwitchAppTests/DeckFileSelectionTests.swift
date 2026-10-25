import AppKit
import XCTest
@testable import LogiEasySwitchApp

final class DeckFileSelectionTests: XCTestCase {
    func testWeblocAndWindowsInternetShortcutParsing() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.test/game"], format: format, options: 0)
            XCTAssertEqual(try DeckFileSelection.shortcutURL(data: data, extension: "webloc").absoluteString, "https://example.test/game")
        }
        let windows = Data("[InternetShortcut]\r\nURL=https://example.test/play\r\nIconIndex=0".utf8)
        XCTAssertEqual(try DeckFileSelection.shortcutURL(data: windows, extension: "url").absoluteString, "https://example.test/play")
        XCTAssertThrowsError(try DeckFileSelection.shortcutURL(data: Data("not a shortcut".utf8), extension: "webloc"))
    }
    func testOrdinaryDocumentStaysLocalAndResolvesToOpenFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let selected = try DeckFileSelection.selecting(file, for: DeckButton())
        XCTAssertEqual(selected.kind, "application")
        XCTAssertEqual(try DeckDesktopActions.file(selected), file)
        var configuration = DeckConfiguration()
        configuration.buttons = [selected]
        let shared = DeckSharedConfiguration(configuration)
        XCTAssertNil(shared.buttons[0].settings["filePath"])
        XCTAssertEqual(shared.applying(to: configuration).buttons[0].settings["filePath"], file.path)
    }
    func testWeblocWithCustomIconConvertsToURLAndEmbedsIcon() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: URL
        if let provided = ProcessInfo.processInfo.environment["SWITCHBOARD_WEBLOC_FIXTURE"] {
            file = URL(fileURLWithPath: provided)
        } else {
            file = directory.appendingPathComponent("Game.webloc")
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL":"https://example.test/game"], format: .xml, options: 0)
            try data.write(to: file)
            let image = try XCTUnwrap(NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil))
            XCTAssertTrue(NSWorkspace.shared.setIcon(image, forFile: file.path, options: []))
        }
        let selected = try DeckFileSelection.selecting(file, for: DeckButton())
        XCTAssertEqual(selected.kind, "url")
        XCTAssertNotNil(selected.settings["url"])
        XCTAssertNil(selected.settings["filePath"])
        XCTAssertEqual(selected.settings["iconSource"], "image")
        XCTAssertNotNil(DeckImageIcons.image(selected))
    }
}
