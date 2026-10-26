import XCTest
@testable import LogiEasySwitchApp

final class DeckProcessRunnerTests: XCTestCase {
    func testExactOutputLimitSucceeds() async throws {
        let result = try await process("/usr/bin/python3", ["-c", "import os; os.write(1,b'x'*65536)"])
        XCTAssertEqual(result.utf8.count, DeckProcessRunner.maximumOutputBytes)
    }

    func testOneByteOverLimitFailsInsteadOfTruncating() async {
        do {
            _ = try await process("/usr/bin/python3", ["-c", "import os; os.write(1,b'x'*65537)"])
            XCTFail("Expected output quota error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit"), "\(error)") }
    }

    func testStdoutAndStderrShareQuota() async {
        do {
            _ = try await process("/usr/bin/python3", ["-c", "import os; os.write(1,b'x'*40000); os.write(2,b'y'*40000)"])
            XCTFail("Expected combined output quota error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("combined output limit"), "\(error)") }
    }

    func testInfiniteOutputIsStoppedPromptly() async {
        let start = ContinuousClock.now
        do {
            _ = try await process("/usr/bin/yes", [])
            XCTFail("Expected output quota error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit"), "\(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testOverflowKillsChildThatIgnoresTermination() async {
        let start = ContinuousClock.now
        do {
            _ = try await process("/usr/bin/python3", ["-c", "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(1,b'x'*100000); time.sleep(10)"])
            XCTFail("Expected output quota error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit"), "\(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testSilentChildTimesOut() async {
        let start = ContinuousClock.now
        do {
            _ = try await DeckProcessRunner.run("/bin/sleep", ["10"], timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit"), "\(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationStopsSilentChild() async {
        let start = ContinuousClock.now
        let task = Task { try await process("/bin/sleep", ["10"]) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testMissingExecutableFailsWithoutHanging() async {
        do {
            _ = try await process("/nonexistent-switchboard-security-test", [])
            XCTFail("Expected spawn failure")
        } catch { /* Launch failures must propagate and close both pipe ends. */ }
    }
}
