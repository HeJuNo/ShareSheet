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
        self.init(configuration: .ephemeral, timeout: timeout, maxBytes: maxBytes)
    }

    /// Test seam: `configuration` can carry stub protocol classes.
    init(configuration: URLSessionConfiguration, timeout: TimeInterval, maxBytes: Int) {
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    /// Streams the body and gives up as soon as it passes `maxBytes` (or declares more up front), so a huge or
    /// endless resource is never held in memory.
    public func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        do {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw BadStatus() }
            let declared = response.expectedContentLength
            if declared > Int64(maxBytes) { throw TooLarge() }
            var data = Data()
            if declared > 0 { data.reserveCapacity(Int(declared)) }
            var chunk = [UInt8]()
            chunk.reserveCapacity(Self.chunkSize)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == Self.chunkSize {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
                if data.count + chunk.count > maxBytes { throw TooLarge() }
            }
            data.append(contentsOf: chunk)
            return (data, response.mimeType)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    private static let chunkSize = 64 * 1024
}

public struct HTMLArchiver: Sendable {
    private let fetcher: any ResourceFetching
    private let totalByteLimit: Int
    private let maxConcurrent: Int

    public init(fetcher: any ResourceFetching, totalByteLimit: Int = 100_000_000) {
        self.init(fetcher: fetcher, totalByteLimit: totalByteLimit, maxConcurrent: 6)
    }

    init(fetcher: any ResourceFetching, totalByteLimit: Int, maxConcurrent: Int) {
        self.fetcher = fetcher
        self.totalByteLimit = totalByteLimit
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func archive(html: String, baseURL: URL) async throws -> String {
        let run = ArchiveRun(fetcher: fetcher, limit: totalByteLimit, maxConcurrent: maxConcurrent)
        return try await run.archive(html: html, baseURL: baseURL)
    }
}

// MARK: - Run state (used sequentially; concurrency is confined to `fetchWave`)

private final class ArchiveRun {
    typealias Fetched = (data: Data, mimeType: String?)
    private let maxConcurrent: Int
    private static let maxImportDepth = 3

    private let fetcher: any ResourceFetching
    private let limit: Int
    private var used = 0
    private var exhausted = false
    private var cache: [URL: Fetched?] = [:]

    init(fetcher: any ResourceFetching, limit: Int, maxConcurrent: Int) {
        self.fetcher = fetcher
        self.limit = limit
        self.maxConcurrent = maxConcurrent
    }

    // MARK: Fetching and budget

    /// Fetches in waves of at most `maxConcurrent` requests. Each wave's bytes are accounted in document
    /// order as it completes; a resource that would exceed the limit is dropped and no further wave is scheduled.
    private func fetchWave(_ urls: [URL]) async -> [URL: Fetched] {
        var pending: [URL] = []
        for url in urls where cache[url] == nil && !pending.contains(url) { pending.append(url) }
        var index = 0
        while index < pending.count, !exhausted, used < limit {
            let chunk = Array(pending[index..<min(index + maxConcurrent, pending.count)])
            index += chunk.count
            let fetcher = self.fetcher
            let results = await withTaskGroup(of: (URL, Fetched?).self) { group -> [URL: Fetched?] in
                for url in chunk {
                    group.addTask { (url, try? await fetcher.fetch(url)) }
                }
                var all: [URL: Fetched?] = [:]
                for await (url, r) in group { all[url] = .some(r) }
                return all
            }
            for url in chunk {
                guard let fetched = results[url] ?? nil else { cache[url] = .some(nil); continue }
                if !exhausted, used + fetched.data.count <= limit {
                    used += fetched.data.count
                    cache[url] = .some(fetched)
                } else {
                    exhausted = true
                    cache[url] = .some(nil)
                }
            }
        }
        var out: [URL: Fetched] = [:]
        for url in urls { if case .some(.some(let f)) = cache[url] { out[url] = f } }
        return out
    }

    // MARK: Entry

    func archive(html: String, baseURL: URL) async throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        doc.outputSettings().prettyPrint(pretty: false).charset(.utf8)
        for node in doc.getChildNodes() where node is DocumentType { try node.remove() }

        // The first <base href> decides how every relative reference resolves.
        var base = baseURL
        if let b = try doc.select("base[href]").first(),
           let resolved = Self.resolve(try b.attr("href"), against: baseURL),
           resolved.isWebPage {
            base = resolved
        }

        try sanitize(doc)
        try cleanLinks(doc, base: base)
        try await inlineResources(doc, base: base)
        try fixHead(doc)

        let stamp = ISO8601DateFormatter().string(from: Date())
        let source = baseURL.absoluteString.replacingOccurrences(of: "--", with: "%2D%2D")
        var out = try doc.outerHtml()
        // SwiftSoup always self-closes void tags; keep the two meta tags we own in plain HTML form.
        out = out.replacingOccurrences(of: "<meta charset=\"utf-8\" />", with: "<meta charset=\"utf-8\">")
        out = out.replacingOccurrences(of: "content=\"\(Self.csp)\" />", with: "content=\"\(Self.csp)\">")
        return "<!DOCTYPE html>\n<!-- saved from \(source) on \(stamp) -->\n" + out
    }

    // MARK: DOM cleanup

    private func sanitize(_ doc: Document) throws {
        try doc.select("script, iframe, object, embed, base, meta[http-equiv=refresh]").remove()
        for meta in try doc.select("meta[http-equiv]").array()
        where try meta.attr("http-equiv").lowercased() == "content-security-policy" { try meta.remove() }
        for el in try doc.select("noscript").array() { try el.unwrap() }
        for el in try doc.getAllElements().array() {
            guard let attrs = el.getAttributes() else { continue }
            for attr in attrs.asList() where attr.getKey().lowercased().hasPrefix("on") {
                try el.removeAttr(attr.getKey())
            }
        }
    }

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    private static let schemePattern = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9+.\-]*):"#)

    /// The link with surrounding whitespace/control characters trimmed, or nil when its scheme is not allowed.
    /// Control characters and whitespace are ignored when detecting the scheme ("java\tscript:").
    private static func safeLink(_ raw: String, allowData: Bool) -> String? {
        let scalars = raw.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7f }
        let compact = String(String.UnicodeScalarView(scalars))
        if let m = schemePattern.firstMatch(in: compact, range: NSRange(location: 0, length: (compact as NSString).length)) {
            let scheme = (compact as NSString).substring(with: m.range(at: 1)).lowercased()
            guard allowedSchemes.contains(scheme) || (allowData && scheme == "data") else { return nil }
        }
        return compact.isEmpty ? "" : raw.trimmingCharacters(in: CharacterSet(charactersIn: " ").union(.controlCharacters).union(.whitespacesAndNewlines))
    }

    private func cleanLinks(_ doc: Document, base: URL) throws {
        func clean(_ el: Element, _ attr: String, allowData: Bool = false, absolute: Bool = true) throws {
            guard el.hasAttr(attr) else { return }
            guard let safe = Self.safeLink(try el.attr(attr), allowData: allowData) else { try el.attr(attr, "#"); return }
            if absolute, !safe.isEmpty, !safe.hasPrefix("#"), !safe.lowercased().hasPrefix("data:"),
               let abs = Self.resolve(safe, against: base) {
                try el.attr(attr, abs.absoluteString)
            } else {
                try el.attr(attr, safe)
            }
        }
        for el in try doc.getAllElements().array() {
            switch el.tagName().lowercased() {
            case "a", "area": try clean(el, "href")
            case "form": try clean(el, "action")
            case "button", "input": try clean(el, "formaction")
            case "image", "use": break   // handled when resources are inlined
            default: break
            }
            if el.hasAttr("xlink:href"), !["image", "use"].contains(el.tagName().lowercased()) { try clean(el, "xlink:href") }
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
    private struct Job {
        let element: Element
        let attr: String
        let url: URL
        let kind: Kind
        var dropOnFailure = false
    }

    private func inlineResources(_ doc: Document, base: URL) async throws {
        var jobs: [Job] = []
        func add(_ el: Element, _ attr: String, _ kind: Kind = .image, dropOnFailure: Bool = true) throws {
            let value = try el.attr(attr)
            if let url = Self.resolve(value, against: base).flatMap({ Self.fetchable($0.absoluteString) }) {
                jobs.append(Job(element: el, attr: attr, url: url, kind: kind, dropOnFailure: dropOnFailure))
            } else if !value.lowercased().hasPrefix("data:") {
                try el.removeAttr(attr)
            }
        }

        for img in try doc.select("img").array() {
            try img.removeAttr("srcset"); try img.removeAttr("sizes"); try img.removeAttr("loading")
            let src = try img.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            let dataSrc = try img.attr("data-src").trimmingCharacters(in: .whitespacesAndNewlines)
            if !dataSrc.isEmpty, Self.isPlaceholder(src), let abs = Self.resolve(dataSrc, against: base) {
                try img.attr("src", abs.absoluteString)
            }
            if let url = Self.fetchable(try img.attr("src")) { jobs.append(Job(element: img, attr: "src", url: url, kind: .image)) }
        }
        for source in try doc.select("source").array() {
            let parent = source.parent()?.tagName().lowercased()
            if parent == "video" || parent == "audio" || !source.hasAttr("src") { try source.remove(); continue }
            try source.removeAttr("srcset"); try source.removeAttr("sizes")
            if let url = Self.fetchable(try source.attr("src")) { jobs.append(Job(element: source, attr: "src", url: url, kind: .image)) }
        }
        for el in try doc.select("video, audio").array() { try el.removeAttr("src") }
        for el in try doc.select("video[poster]").array() { try add(el, "poster") }
        for el in try doc.select("input[type=image][src]").array() { try add(el, "src") }
        for el in try doc.select("[background]").array() { try add(el, "background") }
        for el in try doc.getAllElements().array() {
            let tag = el.tagName().lowercased()
            guard tag == "image" || tag == "use" else { continue }
            for attr in ["href", "xlink:href"] where el.hasAttr(attr) {
                let value = try el.attr(attr)
                if tag == "use" {
                    if !value.hasPrefix("#") { try el.removeAttr(attr) }
                } else if let safe = Self.safeLink(value, allowData: true) {
                    try el.attr(attr, safe)
                    try add(el, attr)
                } else {
                    try el.removeAttr(attr)
                }
            }
        }
        for link in try doc.select("link").array() {
            try link.removeAttr("integrity"); try link.removeAttr("crossorigin")
            let rels = try link.attr("rel").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let isStylesheet = rels.contains("stylesheet")
            let isIcon = rels.contains(where: { $0.contains("icon") })
            guard isStylesheet || isIcon else { try link.remove(); continue }
            if let url = Self.fetchable(try link.attr("href")) {
                jobs.append(Job(element: link, attr: "href", url: url, kind: isStylesheet ? .stylesheet : .icon))
            }
        }

        let fetched = await fetchWave(jobs.map(\.url))
        for job in jobs {
            guard let result = fetched[job.url] else {
                if job.dropOnFailure { try job.element.removeAttr(job.attr) }
                continue
            }
            switch job.kind {
            case .image, .icon:
                try job.element.attr(job.attr, Self.dataURI(result.data, mime: result.mimeType, url: job.url))
            case .stylesheet:
                guard let css = Self.decode(result.data) else { continue }
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
                   let result = fetched[url], let text = Self.decode(result.data) {
                    out += await rewriteCSS(text, base: url, depth: depth + 1, chain: chain.union([url]))
                } else if chain.contains(url) {
                    out += ""   // cycle: drop the import
                } else {
                    out += "@import url(\"\(url.absoluteString)\");"
                }
            } else if let result = fetched[url] {
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
        guard let url = URL(string: trimmed), url.isWebPage else { return nil }
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

    // MARK: Head

    static let csp = "default-src 'none'; img-src data:; media-src data:; font-src data:; style-src 'unsafe-inline' data:"

    private func fixHead(_ doc: Document) throws {
        try doc.select("meta[charset], meta[http-equiv=content-type]").remove()
        guard let head = doc.head() else { return }
        let policy = try head.prependElement("meta")
        try policy.attr("http-equiv", "Content-Security-Policy").attr("content", Self.csp)
        try head.prependElement("meta").attr("charset", "utf-8")
    }
}
