import AppKit

// Validate before invoking Launch Services, keeping URLs and app names out of a shell.
enum DeckDesktopActions {
    static func url(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
              !["javascript", "data"].contains(scheme.lowercased()),
              !["http", "https"].contains(scheme.lowercased()) || !(url.host ?? "").isEmpty else {
            throw DeckError.message("Enter a full URL such as https://example.com or an application link.")
        }
        return url
    }
    static func application(_ button: DeckButton) throws -> URL {
        guard let id = button.settings["applicationBundleID"], !id.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            throw DeckError.message("Choose an application installed on this Mac.")
        }
        return url
    }
    static func file(_ button: DeckButton) throws -> URL {
        if let application = try? application(button) { return application }
        guard let path = button.settings["filePath"], path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw DeckError.message("Choose a file or application installed on this Mac.")
        }
        return URL(fileURLWithPath: path)
    }
    static func launch(_ button: DeckButton) async throws {
        let url = try file(button)
        if url.pathExtension.lowercased() == "app" {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    static func openURL(_ button: DeckButton) async throws {
        let url = try url(button.settings["url"] ?? "")
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }
}
