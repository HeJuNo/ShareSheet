import Foundation
import Testing
import UIKit
@testable import Sharesheet

@MainActor
struct WebPageCapturerTests {
    private final class BundleToken {}

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "html"))
    }

    @Test func capturesFullLongPage() async throws {
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(try fixture("long-page"))

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(image.width == 780)
        #expect(image.height >= 11_000)
        #expect(snapshot.domHTML.contains("lazy-image.png"))
        #expect(snapshot.iconURL != nil)
        #expect(snapshot.truncated == false)
    }

    @Test func stalledPageTimesOutAfterLoad() async throws {
        let capturer = WebPageCapturer(loadTimeout: .seconds(10), postLoadBudget: .seconds(1))
        let url = try fixture("busy-page")
        let start = ContinuousClock.now

        await #expect(throws: CaptureError.timeout) {
            _ = try await capturer.capture(url)
        }

        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func clientRedirectIsNotALoadFailure() async throws {
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(try fixture("redirect-page"))

        #expect(snapshot.finalURL.lastPathComponent == "long-page.html")
    }

    @Test func hostWindowFollowsActiveSceneAndIsHiddenFromAccessibility() async throws {
        let capturer = WebPageCapturer()
        _ = try await capturer.capture(try fixture("long-page"))
        let window = try #require(capturer.hostWindow)
        let active = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        #expect(window.accessibilityElementsHidden)
        if let active { #expect(window.windowScene === active) }
    }
}
