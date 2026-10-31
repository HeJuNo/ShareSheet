import Foundation
import Testing
import UIKit
@testable import Sharesheet

@MainActor
struct WebPageCapturerTests {
    private final class BundleToken {}

    @Test func capturesFullLongPage() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "long-page", withExtension: "html"))
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(url)

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(image.width == 780)
        #expect(image.height >= 11_000)
        #expect(snapshot.domHTML.contains("lazy-image.png"))
        #expect(snapshot.iconURL != nil)
        #expect(snapshot.truncated == false)
    }
}
