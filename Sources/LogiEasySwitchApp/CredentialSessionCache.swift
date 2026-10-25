import Foundation

/// Cache one credential for this process only. A denied read is remembered too,
/// so background polling cannot repeatedly request Keychain authorization.
final class CredentialSessionCache {
    private let lock = NSLock()
    private var attempted = false
    private var value: String?

    func load(retry: Bool = false, read: () -> String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        if !attempted || retry {
            value = read()
            attempted = true
        }
        return value ?? ""
    }

    func save(_ updated: String, write: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        // Only a successful read/save can make a write redundant. Denial is not
        // evidence that the stored credential is empty.
        if attempted, let value, value == updated { return }
        try write()
        value = updated
        attempted = true
    }
}
