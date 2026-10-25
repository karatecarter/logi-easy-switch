import AppKit
import XCTest
@testable import LogiEasySwitchApp

final class DeckDesktopTests: XCTestCase {
    func testURLActionsAcceptWebAndApplicationLinksAndRejectInvalidInputs() throws {
        XCTAssertEqual(try DeckDesktopActions.url(" https://example.com/test ").host, "example.com")
        XCTAssertEqual(try DeckDesktopActions.url("mailto:person@example.com").scheme, "mailto")
        XCTAssertEqual(try DeckDesktopActions.url("shortcuts://run-shortcut?name=Test").scheme, "shortcuts")
        for invalid in ["", "example.com", "https://", "javascript:alert(1)", "data:text/html,test"] {
            XCTAssertThrowsError(try DeckDesktopActions.url(invalid))
        }
    }
    func testApplicationActionRequiresInstalledApplication() {
        var button = DeckButton()
        button.kind = "application"
        XCTAssertThrowsError(try DeckDesktopActions.application(button))
        button.settings["applicationBundleID"] = "invalid.missing.\(UUID().uuidString)"
        XCTAssertThrowsError(try DeckDesktopActions.application(button))
    }
    func testCustomImagesAreNormalizedAndStayWithSyncedButton() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let encoded = try DeckImageIcons.encode(original)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThanOrEqual(data.count, DeckImageIcons.maximumIconBytes)
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(thumbnail.pixelsWide, 128)
        XCTAssertLessThanOrEqual(thumbnail.pixelsHigh, 128)
        var configuration = DeckConfiguration()
        var button = DeckButton()
        button.settings = ["iconSource": "image", "iconImage": encoded]
        configuration.buttons = [button]
        let shared = DeckSharedConfiguration(configuration)
        XCTAssertEqual(shared.applying(to: DeckConfiguration()).buttons[0].settings["iconImage"], encoded)
        XCTAssertNotNil(DeckImageIcons.image(button))
    }
    func testInvalidAndOversizedImagesAreRejected() {
        XCTAssertThrowsError(try DeckImageIcons.encode(Data("not an image".utf8)))
        XCTAssertThrowsError(try DeckImageIcons.encode(Data(repeating: 0, count: DeckImageIcons.maximumSourceBytes + 1)))
        var button = DeckButton()
        button.settings = ["iconSource": "image", "iconImage": "invalid"]
        XCTAssertNil(DeckImageIcons.image(button))
    }
}
