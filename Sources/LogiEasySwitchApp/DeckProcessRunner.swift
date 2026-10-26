import Foundation
import Darwin

/// One pipe for both streams avoids stderr/stdout deadlocks. Nonblocking reads
/// keep cancellation and the deadline responsive even if the child is silent or
/// a descendant inherits the write end. No output is spooled to disk.
enum DeckProcessRunner {
    static let maximumOutputBytes = 65_536

    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(60)) async throws -> String {
        let work = Task.detached {
            let pipe = Pipe()
            let reader = pipe.fileHandleForReading
            let writer = pipe.fileHandleForWriting
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = arguments
            child.standardOutput = writer
            child.standardError = writer
            defer {
                try? writer.close()
                try? reader.close()
                if child.isRunning {
                    child.terminate()
                    // Run on the worker, never the main actor. Escalate if the
                    // child ignores SIGTERM, including on cancellation/overflow.
                    usleep(250_000)
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    child.waitUntilExit()
                }
            }
            let descriptor = reader.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw DeckError.message("Could not configure action output capture.")
            }
            try Task.checkCancellation()
            try child.run()
            try writer.close() // Only the child should hold the pipe open.
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw DeckError.message("Action exceeded its execution time limit.")
                }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard count <= maximumOutputBytes - output.count else {
                        throw DeckError.message("Action exceeded the 64 KiB combined output limit.")
                    }
                    output.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0, !child.isRunning { break }
                if count < 0 {
                    let error = errno
                    if error == EINTR { continue }
                    guard error == EAGAIN || error == EWOULDBLOCK else {
                        throw DeckError.message("Could not read action output (errno \(error)).")
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let text = String(decoding: output, as: UTF8.self)
            guard child.terminationStatus == 0 else {
                throw DeckError.message(text.isEmpty ? "Action failed (\(child.terminationStatus))." : text)
            }
            return text
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
