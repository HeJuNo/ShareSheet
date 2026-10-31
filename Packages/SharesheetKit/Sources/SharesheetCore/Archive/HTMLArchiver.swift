import Foundation
import SwiftSoup

public protocol ResourceFetching: Sendable {
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?)
}

public struct URLSessionFetcher: ResourceFetching {
    struct TooLarge: Error {}
    struct BadStatus: Error {}

    private let session: URLSession
    private let timeout: TimeInterval
    private let maxBytes: Int

    public init(timeout: TimeInterval = 15, maxBytes: Int = 10_000_000) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        self.session = URLSession(configuration: config)
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    public func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw BadStatus() }
        if response.expectedContentLength > Int64(maxBytes) { throw TooLarge() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw TooLarge() }
        }
        return (data, response.mimeType)
    }
}

public struct HTMLArchiver: Sendable {
    private let fetcher: any ResourceFetching
    private let totalByteLimit: Int

    public init(fetcher: any ResourceFetching, totalByteLimit: Int = 100_000_000) {
        self.fetcher = fetcher
        self.totalByteLimit = totalByteLimit
    }

    public func archive(html: String, baseURL: URL) async throws -> String {
        let run = ArchiveRun(fetcher: fetcher, limit: totalByteLimit)
        return try await run.archive(html: html, baseURL: baseURL)
    }
}

// MARK: - Run state (used sequentially; concurrency is confined to `fetchWave`)

private final class ArchiveRun {
    typealias Fetched = (data: Data, mimeType: String?)
    private static let maxConcurrent = 6
    private static let maxImportDepth = 3

    private let fetcher: any ResourceFetching
    private let limit: Int
    private var used = 0
    private var cache: [URL: Fetched?] = [:]

    init(fetcher: any ResourceFetching, limit: Int) {
        self.fetcher = fetcher
        self.limit = limit
    }

    // MARK: Fetching and budget

    /// Fetches in waves of at most 6 concurrent requests. Stops fetching once the byte budget is spent.
    private func fetchWave(_ urls: [URL]) async -> [URL: Fetched] {
        var pending: [URL] = []
        for url in urls where cache[url] == nil && !pending.contains(url) { pending.append(url) }
        var index = 0
        while index < pending.count, used < limit {
            let chunk = Array(pending[index..<min(index + Self.maxConcurrent, pending.count)])
            index += chunk.count
            let fetcher = self.fetcher
            let results = await withTaskGroup(of: (URL, Fetched?).self) { group -> [(URL, Fetched?)] in
                for url in chunk {
                    group.addTask { (url, try? await fetcher.fetch(url)) }
                }
                var all: [(URL, Fetched?)] = []
                for await r in group { all.append(r) }
                return all
            }
            for (url, fetched) in results { cache[url] = .some(fetched) }
        }
        var out: [URL: Fetched] = [:]
        for url in urls { if case .some(.some(let f)) = cache[url] { out[url] = f } }
        return out
    }

    /// Reserves budget for an inlined resource; false when it would exceed the limit.
    private func reserve(_ bytes: Int) -> Bool {
        guard used + bytes <= limit else { used = limit; return false }
        used += bytes
        return true
    }

    // MARK: Entry

    func archive(html: String, baseURL: URL) async throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        doc.outputSettings().prettyPrint(pretty: false).charset(.utf8)
        for node in doc.getChildNodes() where node is DocumentType { try node.remove() }

        try sanitize(doc)
        try absolutize(doc, base: baseURL)
        try await inlineResources(doc, base: baseURL)
        try fixCharset(doc)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let source = baseURL.absoluteString.replacingOccurrences(of: "--", with: "%2D%2D")
        return "<!DOCTYPE html>\n<!-- saved from \(source) on \(stamp) -->\n" + (try doc.outerHtml())
            .replacingOccurrences(of: "<meta charset=\"utf-8\" />", with: "<meta charset=\"utf-8\">")  // SwiftSoup always self-closes void tags
    }

    // MARK: DOM cleanup

    private func sanitize(_ doc: Document) throws {
        try doc.select("script, iframe, object, embed, base, meta[http-equiv=refresh]").remove()
        for el in try doc.select("noscript").array() { try el.unwrap() }
        for el in try doc.getAllElements().array() {
            guard let attrs = el.getAttributes() else { continue }
            for attr in attrs.asList() where attr.getKey().lowercased().hasPrefix("on") {
                try el.removeAttr(attr.getKey())
            }
        }
    }

    private func absolutize(_ doc: Document, base: URL) throws {
        for a in try doc.select("a[href]").array() {
            let href = try a.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = href.lowercased()
            if lower.hasPrefix("javascript:") { try a.attr("href", "#"); continue }
            if href.isEmpty || href.hasPrefix("#") || lower.hasPrefix("data:") || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") { continue }
            if let abs = Self.resolve(href, against: base) { try a.attr("href", abs.absoluteString) }
        }
        for (selector, attr) in [("img[src]", "src"), ("source[src]", "src"), ("link[href]", "href")] {
            for el in try doc.select(selector).array() {
                let value = try el.attr(attr)
                if let abs = Self.resolve(value, against: base) { try el.attr(attr, abs.absoluteString) }
            }
        }
    }

    // MARK: Inlining

    private enum Kind { case image, icon, stylesheet }
    private struct Job { let element: Element; let url: URL; let kind: Kind }

    private func inlineResources(_ doc: Document, base: URL) async throws {
        var jobs: [Job] = []

        for img in try doc.select("img").array() {
            try img.removeAttr("srcset"); try img.removeAttr("sizes"); try img.removeAttr("loading")
            var src = try img.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            let dataSrc = try img.attr("data-src").trimmingCharacters(in: .whitespacesAndNewlines)
            if !dataSrc.isEmpty, Self.isPlaceholder(src), let abs = Self.resolve(dataSrc, against: base) {
                src = abs.absoluteString
                try img.attr("src", src)
            }
            if let url = Self.fetchable(src) { jobs.append(Job(element: img, url: url, kind: .image)) }
        }
        for source in try doc.select("source").array() {
            try source.removeAttr("srcset"); try source.removeAttr("sizes")
            guard source.hasAttr("src") else { try source.remove(); continue }
            if let url = Self.fetchable(try source.attr("src")) { jobs.append(Job(element: source, url: url, kind: .image)) }
        }
        for link in try doc.select("link").array() {
            try link.removeAttr("integrity"); try link.removeAttr("crossorigin")
            let rels = try link.attr("rel").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard let url = Self.fetchable(try link.attr("href")) else { continue }
            if rels.contains("stylesheet") {
                jobs.append(Job(element: link, url: url, kind: .stylesheet))
            } else if rels.contains(where: { $0.contains("icon") }) {
                jobs.append(Job(element: link, url: url, kind: .icon))
            }
        }

        let fetched = await fetchWave(jobs.map(\.url))
        for job in jobs {
            guard let result = fetched[job.url], reserve(result.data.count) else { continue }
            switch job.kind {
            case .image:
                try job.element.attr("src", Self.dataURI(result.data, mime: result.mimeType, url: job.url))
            case .icon:
                try job.element.attr("href", Self.dataURI(result.data, mime: result.mimeType, url: job.url))
            case .stylesheet:
                guard let css = Self.decode(result.data) else { used -= result.data.count; continue }
                let rewritten = await rewriteCSS(css, base: job.url, depth: 0, chain: [job.url])
                let style = try Element(Tag.valueOf("style"), "")
                if job.element.hasAttr("media") { try style.attr("media", try job.element.attr("media")) }
                try style.appendChild(DataNode(Array(Self.escapeStyle(rewritten).utf8), []))
                try job.element.replaceWith(style)
            }
        }

        for style in try doc.select("style").array() {
            let css = style.data()
            guard css.contains("url(") || css.contains("@import") else { continue }
            let rewritten = await rewriteCSS(css, base: base, depth: 0, chain: [])
            style.empty()
            try style.appendChild(DataNode(Array(Self.escapeStyle(rewritten).utf8), []))
        }
        for el in try doc.select("[style]").array() {
            let css = try el.attr("style")
            guard css.contains("url(") else { continue }
            try el.attr("style", await rewriteCSS(css, base: base, depth: Self.maxImportDepth, chain: []))
        }
    }

    // MARK: CSS

    // Groups: 1,2 = @import url(...); 3,4 = @import "..."; 5,6 = url(...)
    private static let cssPattern = try! NSRegularExpression(
        pattern: #"@import\s+(?:url\(\s*(['"]?)([^'")]+)\1\s*\)|(['"])([^'"]+)\3)[^;]*;|url\(\s*(['"]?)([^'")]*)\5\s*\)"#,
        options: [.caseInsensitive])

    private func rewriteCSS(_ css: String, base: URL, depth: Int, chain: Set<URL>) async -> String {
        let ns = css as NSString
        let matches = Self.cssPattern.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }

        struct Piece { let range: NSRange; let isImport: Bool; let url: URL? }
        var pieces: [Piece] = []
        for m in matches {
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let importRef = group(2) ?? group(4)
            let isImport = importRef != nil
            let ref = (importRef ?? group(6) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            pieces.append(Piece(range: m.range, isImport: isImport,
                                url: Self.resolve(ref, against: base).flatMap { Self.fetchable($0.absoluteString) }))
        }

        let fetched = await fetchWave(pieces.compactMap { $0.url })
        var out = ""
        var cursor = 0
        for piece in pieces {
            out += ns.substring(with: NSRange(location: cursor, length: piece.range.location - cursor))
            cursor = piece.range.location + piece.range.length
            let original = ns.substring(with: piece.range)
            guard let url = piece.url else { out += original; continue }

            if piece.isImport {
                if depth < Self.maxImportDepth, !chain.contains(url),
                   let result = fetched[url], let text = Self.decode(result.data), reserve(result.data.count) {
                    out += await rewriteCSS(text, base: url, depth: depth + 1, chain: chain.union([url]))
                } else if chain.contains(url) {
                    out += ""   // cycle: drop the import
                } else {
                    out += "@import url(\"\(url.absoluteString)\");"
                }
            } else if let result = fetched[url], reserve(result.data.count) {
                out += "url(\"\(Self.dataURI(result.data, mime: result.mimeType, url: url))\")"
            } else {
                out += "url(\"\(url.absoluteString)\")"
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: Helpers

    private static func resolve(_ ref: String, against base: URL) -> URL? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    /// An absolute http(s) URL worth fetching; nil for data:, fragments, other schemes.
    private static func fetchable(_ ref: String) -> URL? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func isPlaceholder(_ src: String) -> Bool {
        src.isEmpty || src.lowercased().hasPrefix("data:") || src.lowercased().contains("placeholder")
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func escapeStyle(_ css: String) -> String {
        css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
    }

    private static func dataURI(_ data: Data, mime: String?, url: URL) -> String {
        let declared = mime?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let type = (declared?.isEmpty == false ? declared : nil) ?? guessMime(url)
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    private static func guessMime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }

    // MARK: Charset

    private func fixCharset(_ doc: Document) throws {
        try doc.select("meta[charset], meta[http-equiv=content-type]").remove()
        guard let head = doc.head() else { return }
        try head.prependElement("meta").attr("charset", "utf-8")
    }
}
