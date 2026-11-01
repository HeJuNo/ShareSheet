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

    @Test func snapshotContainsRenderedContentTopToBottom() async throws {
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(try fixture("color-page"))

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        let top = pixel(image, x: 390, y: 100)
        let bottom = pixel(image, x: 390, y: image.height - 100)
        #expect(isClose(top, to: [255, 0, 0]), "top pixel \(top)")
        #expect(isClose(bottom, to: [0, 0, 255]), "bottom pixel \(bottom)")
    }

    /// Colour matching tolerates small differences from colour-space conversion.
    private func isClose(_ rgb: [UInt8], to expected: [UInt8]) -> Bool {
        zip(rgb, expected).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
    }

    /// The RGB value of one pixel, read from a redraw in a known sRGB format.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(data.prefix(3))
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
