import AppKit
import Darwin

/// Selecting a web shortcut imports its destination and icon; the source file is
/// no longer needed after conversion. Ordinary files stay local to each Mac.
enum DeckFileSelection {
    static func shortcutURL(data: Data, extension suffix: String) throws -> URL {
        let destination: String?
        switch suffix.lowercased() {
        case "webloc", "inetloc":
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            destination = plist?["URL"] as? String
        case "url":
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
            var inShortcut = false
            var result: String?
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") { inShortcut = trimmed.lowercased() == "[internetshortcut]" }
                if inShortcut, let equal = trimmed.firstIndex(of: "="), trimmed[..<equal].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                    result = String(trimmed[trimmed.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            destination = result
        default: destination = nil
        }
        guard let destination else { throw DeckError.message("This Internet Shortcut does not contain a valid URL.") }
        return try DeckDesktopActions.url(destination)
    }
    static func customIcon(_ file: URL) -> NSImage? {
        if let values = try? (file as NSURL).resourceValues(forKeys: [.customIconKey]), let icon = values[.customIconKey] as? NSImage { return icon }
        // Finder custom icons stored in resource forks may not be exposed by
        // customIconKey. Check the Finder flag before using the effective icon.
        var finderInfo = [UInt8](repeating: 0, count: 32)
        let count = finderInfo.withUnsafeMutableBytes { buffer in
            file.withUnsafeFileSystemRepresentation { path -> Int in
                guard let path else { return -1 }
                return getxattr(path, "com.apple.FinderInfo", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard count >= 10, finderInfo[8] & 0x04 != 0 else { return nil }
        return NSWorkspace.shared.icon(forFile: file.path)
    }
    static func selecting(_ file: URL, for original: DeckButton) throws -> DeckButton {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { throw DeckError.message("Choose an existing file or application.") }
        var button = original
        let suffix = file.pathExtension.lowercased()
        let name = file.deletingPathExtension().lastPathComponent
        if ["webloc", "inetloc", "url"].contains(suffix) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1024 * 1024 else { throw DeckError.message("Internet Shortcut exceeds the 1 MB limit.") }
            let destination = try shortcutURL(data: Data(contentsOf: file), extension: suffix)
            button.kind = "url"
            button.settings["url"] = destination.absoluteString
            for key in ["filePath", "fileName", "applicationBundleID", "applicationName", "faviconPage", "faviconImage", "faviconSource"] { button.settings.removeValue(forKey: key) }
            if let image = customIcon(file) {
                button.settings["iconImage"] = try DeckImageIcons.encode(image)
                button.settings["iconSource"] = "image"
            } else if original.settings["iconSource"] == "application" {
                button.settings["iconSource"] = "symbol"
                button.icon = "globe"
            }
        } else {
            button.kind = "application" // Preserve compatibility with existing application actions.
            button.settings["filePath"] = file.path
            button.settings["fileName"] = file.lastPathComponent
            button.settings.removeValue(forKey: "applicationBundleID")
            button.settings.removeValue(forKey: "applicationName")
            if suffix == "app", let bundle = Bundle(url: file), let id = bundle.bundleIdentifier {
                button.settings["applicationBundleID"] = id
                button.settings["applicationName"] = name
            }
            if button.settings["iconSource"] == nil || button.settings["iconSource"] == "favicon" { button.settings["iconSource"] = "application" }
        }
        if button.name == "New shortcut" { button.name = name }
        return button
    }
}
