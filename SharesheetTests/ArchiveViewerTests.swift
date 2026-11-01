import Foundation
import Testing
@testable import Sharesheet

struct ArchiveViewerTests {
    private let archive = URL(fileURLWithPath: "/Library/_attachments/page-2026-10-31.html")

    @Test func onlyTheArchiveItselfLoads() {
        #expect(ArchiveNavigation.decide(archive, archive: archive, isLinkActivated: false) == .allow)
        let anchor = URL(string: archive.absoluteString + "#section")!
        #expect(ArchiveNavigation.decide(anchor, archive: archive, isLinkActivated: true) == .allow)
    }

    @Test func otherFilesNeverLoad() {
        for path in ["/Library/_attachments/other.html", "/Library/_attachments/shot.png", "/etc/hosts",
                     "/Library/_attachments/page-2026-10-31.html/../secret.md"] {
            let target = URL(fileURLWithPath: path)
            #expect(ArchiveNavigation.decide(target, archive: archive, isLinkActivated: true) == .cancel)
        }
    }

    @Test func tappedWebLinksOpenOutside() {
        let web = URL(string: "https://example.com/next")!
        #expect(ArchiveNavigation.decide(web, archive: archive, isLinkActivated: true) == .openExternally)
        #expect(ArchiveNavigation.decide(web, archive: archive, isLinkActivated: false) == .cancel)
        #expect(ArchiveNavigation.decide(URL(string: "javascript:alert(1)")!, archive: archive, isLinkActivated: true) == .cancel)
        #expect(ArchiveNavigation.decide(nil, archive: archive, isLinkActivated: true) == .cancel)
    }
}
