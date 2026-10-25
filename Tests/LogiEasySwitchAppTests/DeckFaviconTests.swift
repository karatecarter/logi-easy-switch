import AppKit
import XCTest
@testable import LogiEasySwitchApp

final class DeckFaviconTests: XCTestCase {
    func testFindsRelativeAndTouchIconsWithoutDownloadingUnsafeSchemes() throws {
        let page = try XCTUnwrap(URL(string: "https://example.test/sub/page?q=1"))
        let html = """
        <LINK href='../brand.png?x=1&amp;y=2' REL='shortcut ICON'>
        <link rel=apple-touch-icon href=/touch.png>
        <link href='data:image/png,abc' rel='icon'>
        <link rel=stylesheet href=/style.css>
        """
        let urls = DeckFavicon.candidates(html: html, page: page).map(\.absoluteString)
        XCTAssertEqual(urls, ["https://example.test/brand.png?x=1&y=2", "https://example.test/touch.png", "https://example.test/favicon.ico"])
    }
    func testDownloadFallsBackAndReturnsOfflineCacheImage() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var requests: [String] = []
        let result = try await DeckFavicon.download("https://example.test/page", fetch: { url, _ in
            requests.append(url.path)
            if url.path == "/page" { return (Data("<link rel='icon' href='/bad.svg'>".utf8), url) }
            if url.path == "/bad.svg" { return (Data("not a raster icon".utf8), url) }
            return (png, url)
        })
        XCTAssertEqual(requests, ["/page", "/bad.svg", "/favicon.ico"])
        XCTAssertEqual(result.source.path, "/favicon.ico")
        var button = DeckButton()
        button.settings = ["iconSource":"favicon", "faviconImage":result.image]
        XCTAssertNotNil(DeckImageIcons.image(button))
        var configuration = DeckConfiguration()
        configuration.buttons = [button]
        let restored = DeckSharedConfiguration(configuration).applying(to: DeckConfiguration())
        XCTAssertEqual(restored.buttons[0].settings["faviconImage"], result.image)
    }
    func testFallbackIsRetainedEvenWhenPageHasManyIcons() throws {
        let html = (1...12).map { "<link rel='icon' href='/icon\($0).svg'>" }.joined()
        let urls = DeckFavicon.candidates(html: html, page: try XCTUnwrap(URL(string: "https://example.test/deep/path")))
        XCTAssertEqual(urls.count, 8)
        XCTAssertEqual(urls.last?.path, "/favicon.ico")
    }
    func testNonWebURLsAndEmbeddedCredentialsAreRejected() {
        for value in ["mailto:a@example.test", "file:///tmp/image", "https://user:secret@example.test", "example.test"] {
            XCTAssertThrowsError(try DeckFavicon.pageURL(value))
        }
    }
}
