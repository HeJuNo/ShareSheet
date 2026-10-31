import Testing
import Foundation
@testable import SharesheetCore

struct StubFetcher: ResourceFetching {
    struct NotFound: Error {}
    var responses: [URL: (Data, String?)]
    func fetch(_ url: URL) async throws -> (data: Data, mimeType: String?) {
        guard let r = responses[url] else { throw NotFound() }
        return (r.0, r.1)
    }
}

private let base = URL(string: "https://example.com/")!
private func u(_ s: String) -> URL { URL(string: s)! }
private func archiver(_ r: [URL: (Data, String?)], limit: Int = 100_000_000) -> HTMLArchiver {
    HTMLArchiver(fetcher: StubFetcher(responses: r), totalByteLimit: limit)
}
private func data(_ s: String) -> Data { Data(s.utf8) }

@Suite struct HTMLArchiverTests {
    @Test func removesScriptsAndEventHandlers() async throws {
        let out = try await archiver([:]).archive(html: #"<html><body onload="x()"><script>evil()</script><a href="/p" onclick="y()">l</a></body></html>"#, baseURL: base)
        #expect(!out.contains("<script") && !out.contains("onload") && !out.contains("onclick"))
        #expect(out.contains(#"href="https://example.com/p""#))
    }

    @Test func removesFramesBaseRefreshAndUnwrapsNoscript() async throws {
        let html = ##"<html><head><base href="https://evil/"><meta http-equiv="refresh" content="0;url=/x"></head><body><iframe src="/f"></iframe><object data="o"></object><embed src="e"><noscript><p>kept</p></noscript><a href="javascript:alert(1)">j</a><a href="mailto:a@b.c">m</a><a href="#top">t</a></body></html>"##
        let out = try await archiver([:]).archive(html: html, baseURL: base)
        #expect(!out.contains("<iframe") && !out.contains("<object") && !out.contains("<embed"))
        #expect(!out.contains("<base") && !out.contains("refresh") && !out.contains("<noscript"))
        #expect(out.contains("<p>kept</p>"))
        #expect(out.contains("href=\"#\"") && out.contains(#"href="mailto:a@b.c""#) && out.contains("href=\"#top\""))
        #expect(!out.contains("javascript:"))
    }

    @Test func inlinesImagesAsDataURIs() async throws {
        let bytes = Data([1, 2, 3, 4])
        let a = archiver([u("https://example.com/a.png"): (bytes, nil)])
        let out = try await a.archive(html: #"<img src="/a.png" srcset="/a2.png 2x" sizes="100vw" loading="lazy">"#, baseURL: base)
        #expect(out.contains("src=\"data:image/png;base64,\(bytes.base64EncodedString())\""))
        #expect(!out.contains("srcset") && !out.contains("sizes") && !out.contains("loading"))
    }

    @Test func usesResponseMimeAndLazyDataSrc() async throws {
        let a = archiver([u("https://example.com/real.jpg"): (Data([9]), "image/jpeg")])
        let out = try await a.archive(html: #"<img src="data:image/gif;base64,R0lGOD" data-src="/real.jpg">"#, baseURL: base)
        #expect(out.contains("src=\"data:image/jpeg;base64,CQ==\""))
    }

    @Test func inlinesStylesheetsAndTheirURLs() async throws {
        let a = archiver([
            u("https://example.com/s.css"): (data(#"@import "b.css"; body{background:url(img/bg.png)} @font-face{src:url('font.woff2')}"#), "text/css"),
            u("https://example.com/b.css"): (data("h1{color:red}"), "text/css"),
            u("https://example.com/img/bg.png"): (Data([1]), nil),
            u("https://example.com/font.woff2"): (Data([2]), nil),
        ])
        let out = try await a.archive(html: #"<head><link rel="stylesheet" href="s.css" integrity="x" crossorigin="anonymous"></head>"#, baseURL: base)
        #expect(out.contains("<style>") && !out.contains("<link"))
        #expect(out.contains("h1{color:red}"))
        #expect(out.contains("data:image/png;base64,AQ=="))
        #expect(out.contains("data:font/woff2;base64,Ag=="))
        #expect(!out.contains("@import") && !out.contains("integrity"))
    }

    @Test func importCyclesTerminate() async throws {
        let a = archiver([
            u("https://example.com/a.css"): (data(#"@import url(b.css); a{}"#), "text/css"),
            u("https://example.com/b.css"): (data(#"@import url("a.css"); b{}"#), "text/css"),
        ])
        let out = try await a.archive(html: #"<link rel="stylesheet" href="a.css">"#, baseURL: base)
        #expect(out.contains("a{}") && out.contains("b{}"))
    }

    @Test func rewritesInlineStyleBlocks() async throws {
        let a = archiver([u("https://example.com/x.png"): (Data([1]), nil)])
        let out = try await a.archive(html: #"<style>p{background:url(x.png)}</style><div style="background:url('x.png')"></div>"#, baseURL: base)
        #expect(!out.contains("x.png"))
    }

    @Test func skipsFailedResourcesKeepingAbsoluteURL() async throws {
        let out = try await archiver([:]).archive(html: #"<img src="missing.png">"#, baseURL: base)
        #expect(out.contains(#"src="https://example.com/missing.png""#))
    }

    @Test func respectsTotalByteLimit() async throws {
        let eight = Data(repeating: 7, count: 8)
        let a = archiver([u("https://example.com/1.png"): (eight, nil), u("https://example.com/2.png"): (eight, nil)], limit: 10)
        let out = try await a.archive(html: #"<img src="/1.png"><img src="/2.png">"#, baseURL: base)
        #expect(out.contains("data:image/png;base64,"))
        #expect(out.contains(#"src="https://example.com/2.png""#))
        #expect(!out.contains(#"src="https://example.com/1.png""#))
    }

    @Test func addsCharsetAndSourceComment() async throws {
        let out = try await archiver([:]).archive(html: #"<html><head><meta charset="latin1"><title>t</title></head><body>x</body></html>"#, baseURL: base)
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<!-- saved from https://example.com/"))
        #expect(out.contains(#"<meta charset="utf-8">"#) && !out.contains("latin1"))
        let head = try #require(out.range(of: "<head>"))
        #expect(out[head.upperBound...].hasPrefix(#"<meta charset="utf-8">"#))
    }

    @Test func extractsVisibleText() {
        #expect(ArchiveText.extract(fromHTML: "<p>Hello <b>world</b></p><style>x{}</style>") == "Hello world")
        #expect(ArchiveText.extract(fromHTML: "<head><title>T</title></head><body>\n a \n\n b <script>x()</script><noscript>n</noscript><template>t</template></body>") == "a b")
    }
}
