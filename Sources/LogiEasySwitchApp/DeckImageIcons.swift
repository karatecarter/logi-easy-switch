import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Store normalized thumbnails with the button so image icons survive sync and backups.
enum DeckImageIcons {
    static let maximumSourceBytes = 20 * 1024 * 1024
    static let maximumIconBytes = 12 * 1024
    static func encode(_ image: NSImage) throws -> String {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), image.size.width > 0, image.size.height > 0 else {
            throw DeckError.message("Could not render this file's custom icon.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
        let scale = min(128 / image.size.width, 128 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DeckError.message("Could not import the file icon.") }
        return try encode(data)
    }
    static func encode(_ data: Data) throws -> String {
        guard data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DeckError.message("Choose an image file up to 20 MB.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 64_000_000 else {
            throw DeckError.message("Choose an image with no more than 64 million pixels.")
        }
        for size in [128, 96, 64, 48, 32] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maximumIconBytes {
                return png.base64EncodedString()
            }
        }
        throw DeckError.message("Could not convert this image into an icon. Try PNG or JPEG.")
    }
    static func image(_ button: DeckButton) -> NSImage? {
        switch button.settings["iconSource"] {
        case "image", "favicon":
            guard let value = button.settings[button.settings["iconSource"] == "favicon" ? "faviconImage" : "iconImage"], value.utf8.count <= maximumIconBytes * 2,
                  let data = Data(base64Encoded: value), data.count <= maximumIconBytes else { return nil }
            return NSImage(data: data)
        case "application":
            guard let url = try? DeckDesktopActions.file(button) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        default: return nil
        }
    }
}

struct DeckButtonIcon: View {
    var button: DeckButton
    var presentation: DeckPresentation?
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let image = DeckImageIcons.image(button) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
            } else {
                Image(systemName: presentation?.icon ?? (DeckHATarget.automaticLight(button) ? "lightbulb" : button.icon))
                    .font(.system(size: size))
                    .foregroundStyle(presentation?.highlighted == true ? Color.yellow : (presentation?.highlighted == false ? Color.secondary : Color.primary))
            }
        }.accessibilityHidden(true)
    }
}

struct DeckIconOptions: View {
    @Binding var button: DeckButton
    @State private var error: String?
    @State private var fetchingFavicon = false
    @State private var faviconRefresh = UUID()
    private var faviconRequest: String {
        guard button.kind == "url", button.settings["iconSource"] == "favicon" else { return "" }
        return button.id.uuidString + (button.settings["url"] ?? "") + faviconRefresh.uuidString
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Icon")
                DeckButtonIcon(button: button)
                Picker("Icon source", selection: Binding(get: { button.settings["iconSource"] ?? "symbol" }, set: { value in
                    button.settings["iconSource"] = value
                    if value != "symbol" { button.settings["automaticLightIcon"] = "false" }
                })) {
                    Text("Symbol").tag("symbol")
                    Text("Custom image").tag("image")
                    if button.kind == "url" { Text("Favicon").tag("favicon") }
                    if button.kind == "application" { Text("File / application icon").tag("application") }
                }.labelsHidden()
            }
            if button.settings["iconSource"] == "favicon" {
                HStack {
                    Button("Refresh favicon") {
                        button.settings.removeValue(forKey: "faviconPage")
                        faviconRefresh = UUID()
                    }.disabled(fetchingFavicon)
                    if fetchingFavicon { ProgressView().controlSize(.small); Text("Downloading favicon…").font(.caption) }
                    else if button.settings["faviconPage"] == button.settings["url"] { Text("Cached for offline use").font(.caption).foregroundStyle(.secondary) }
                }
            } else if button.settings["iconSource"] == "image" {
                HStack {
                    Button("Choose image file…") { chooseImage() }
                    Button("Paste image") { pasteImage() }
                }
            } else if button.settings["iconSource"] != "application" {
                DeckIconPicker(icon: Binding(get: { button.icon }, set: { value in
                    button.icon = value
                    button.settings["iconSource"] = "symbol"
                    button.settings["automaticLightIcon"] = "false"
                }))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: faviconRequest) {
            fetchingFavicon = false
            error = nil
            guard !faviconRequest.isEmpty else { return }
            let page = button.settings["url"] ?? ""
            guard button.settings["faviconPage"] != page || DeckImageIcons.image(button) == nil else { return }
            fetchingFavicon = true
            do {
                // Debounce URL typing; selecting Favicon with an existing URL starts immediately after this short pause.
                try await Task.sleep(for: .milliseconds(250))
                let icon = try await DeckFavicon.download(page)
                try Task.checkCancellation()
                button.settings["faviconImage"] = icon.image
                button.settings["faviconPage"] = page
                button.settings["faviconSource"] = icon.source.absoluteString
                fetchingFavicon = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                fetchingFavicon = false
            }
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= DeckImageIcons.maximumSourceBytes else { throw DeckError.message("Choose an image file up to 20 MB.") }
            try useImage(Data(contentsOf: url))
        } catch { self.error = error.localizedDescription }
    }
    private func pasteImage() {
        let board = NSPasteboard.general
        do {
            if let data = board.data(forType: .png) ?? board.data(forType: .tiff) { try useImage(data) }
            else if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= DeckImageIcons.maximumSourceBytes else { throw DeckError.message("Choose an image file up to 20 MB.") }
                try useImage(Data(contentsOf: url))
            } else { throw DeckError.message("Copy an image or image file, then choose Paste image.") }
        } catch { self.error = error.localizedDescription }
    }
    private func useImage(_ data: Data) throws {
        button.settings["iconImage"] = try DeckImageIcons.encode(data)
        button.settings["iconSource"] = "image"
        error = nil
    }
}

struct DeckApplicationEditor: View {
    @Binding var button: DeckButton
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(button.settings["fileName"] ?? button.settings["applicationName"] ?? "No file selected").lineLimit(1)
                Button("Choose file…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.treatsFilePackagesAsDirectories = false
                    panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do {
                        button = try DeckFileSelection.selecting(url, for: button)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            Text("Open an application or document. Internet Shortcuts convert to Open URL and import their custom icon.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
