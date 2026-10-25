import Foundation

enum DeckFavicon {
    struct Result { var image: String; var source: URL }
    static func pageURL(_ text: String) throws -> URL {
        let url = try DeckDesktopActions.url(text)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw DeckError.message("Favicons require an HTTP or HTTPS URL without embedded credentials.")
        }
        return url
    }
    static func candidates(html: String, page: URL) -> [URL] {
        let links = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
        let attributes = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        var result: [URL] = []
        for link in links.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(link.range, in: html) else { continue }
            let tag = String(html[range])
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let keyRange = Range(attribute.range(at: 1), in: tag) else { continue }
                for index in 2...4 {
                    if let valueRange = Range(attribute.range(at: index), in: tag) {
                        values[tag[keyRange].lowercased()] = String(tag[valueRange]); break
                    }
                }
            }
            let relations = (values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace })
            guard relations.contains("icon") || relations.contains("apple-touch-icon"), let href = values["href"],
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
                  !result.contains(url) else { continue }
            result.append(url)
        }
        if var origin = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            origin.path = "/favicon.ico"
            origin.query = nil
            origin.fragment = nil
            if let url = origin.url, !result.contains(url) { return Array(result.prefix(7)) + [url] }
        }
        return Array(result.prefix(8))
    }
    static func download(_ text: String) async throws -> Result {
        _ = try pageURL(text)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await download(text, fetch: { url, limit in
            try await fetch(url, limit: limit, session: session)
        })
    }
    static func download(_ text: String, fetch: (URL, Int) async throws -> (Data, URL)) async throws -> Result {
        let page = try pageURL(text)
        var html = ""
        var resolved = page
        do {
            let (data, responseURL) = try await fetch(page, 512 * 1024)
            html = String(decoding: data, as: UTF8.self)
            resolved = responseURL
        } catch {
            try Task.checkCancellation()
            // Even a protected or non-HTML page may expose /favicon.ico.
        }
        for url in candidates(html: html, page: resolved) {
            try Task.checkCancellation()
            do {
                let (data, _) = try await fetch(url, 2 * 1024 * 1024)
                return Result(image: try DeckImageIcons.encode(data), source: url)
            } catch { try Task.checkCancellation() }
        }
        throw DeckError.message("No supported favicon found. Choose a custom image or symbol instead.")
    }
    private static func fetch(_ url: URL, limit: Int, session: URLSession) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= limit else { throw DeckError.message("Favicon request failed or exceeded its size limit.") }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw DeckError.message("Favicon response exceeded its size limit.") }
            data.append(byte)
        }
        return (data, response.url ?? url)
    }
}
