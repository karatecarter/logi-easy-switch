import AppKit
import Foundation

/// Local-only follow-up actions. Never supplied by MQTT payloads or shortcut sync.
struct DestinationSwitchAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable {
        case none, command, application
        var label: String {
            switch self { case .none: "Nothing"; case .command: "Run command"; case .application: "Open application" }
        }
    }
    var kind: Kind = .none
    var command = ""
    var applicationPath = ""
    var isEmpty: Bool {
        switch kind {
        case .none: true
        case .command: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .application: applicationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    func applicationURL() throws -> URL {
        let path = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: path) else {
            throw DeckError.message("Choose an application installed on this Mac.")
        }
        return url
    }
    func execute() async throws {
        guard !isEmpty else { return }
        switch kind {
        case .none: break
        case .command:
            // The shell source is explicitly entered locally by the user. Destination
            // names and MQTT strings are never interpolated into it.
            _ = try await DeckProcessRunner.run("/bin/zsh", ["-c", command], timeout: .seconds(30))
        case .application:
            let url = try applicationURL()
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Serialize follow-up actions when multiple switching requests arrive quickly.
actor DestinationActionRunner {
    private var tail: Task<Void, Error>?
    func run(_ action: DestinationSwitchAction) async throws {
        guard !action.isEmpty else { return }
        let previous = tail
        let task = Task {
            _ = await previous?.result
            try await action.execute()
        }
        tail = task
        try await task.value
    }
}

/// Exactly one follow-up per completed local switch/request, not per peripheral.
/// A network request can have no devices on this Mac while a peer moves them.
enum DestinationSwitchFlow {
    static func perform(pendingCount: Int, networkRequest: Bool = false,
                        switchDevices: () async throws -> Void,
                        followUp: () async throws -> Void) async throws {
        try await switchDevices()
        if pendingCount > 0 || networkRequest { try await followUp() }
    }
}
