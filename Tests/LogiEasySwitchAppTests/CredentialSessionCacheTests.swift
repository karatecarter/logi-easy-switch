import XCTest
@testable import LogiEasySwitchApp

final class CredentialSessionCacheTests: XCTestCase {
    func testRepeatedLoadsAndUnchangedSaveDoNotAccessKeychainAgain() throws {
        let cache = CredentialSessionCache()
        var reads = 0
        let read: () -> String? = { reads += 1; return "credential" }
        XCTAssertEqual(cache.load(read: read), "credential")
        XCTAssertEqual(cache.load(read: read), "credential")
        try cache.save("credential") { XCTFail("No write needed when settings populate from cache") }
        XCTAssertEqual(reads, 1)
    }
    func testDeniedReadDoesNotKeepPromptingAndExplicitRetryCanRecover() {
        let cache = CredentialSessionCache()
        var reads = 0
        XCTAssertEqual(cache.load { reads += 1; return nil }, "")
        XCTAssertEqual(cache.load { reads += 1; return nil }, "")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(cache.load(retry: true) { reads += 1; return "allowed" }, "allowed")
        XCTAssertEqual(reads, 2)
    }
    func testSuccessfulSaveUpdatesSessionAndFailedSavePreservesIt() throws {
        let cache = CredentialSessionCache()
        try cache.save("saved") {}
        XCTAssertEqual(cache.load { XCTFail("Should use saved value"); return nil }, "saved")
        XCTAssertThrowsError(try cache.save("failed") { throw DeckError.message("Denied") })
        XCTAssertEqual(cache.load { nil }, "saved")
    }
    func testDeniedReadDoesNotTreatEmptyAsKnownStoredCredential() throws {
        let cache = CredentialSessionCache()
        _ = cache.load { nil }
        var wrote = false
        try cache.save("") { wrote = true }
        XCTAssertTrue(wrote)
    }
}
