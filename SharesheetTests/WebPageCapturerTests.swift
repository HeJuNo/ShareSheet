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

    /// Stretching the web view to the full page height must not stretch `100vh` sections with it.
    @Test func viewportHeightStaysAtPhoneSizeInFullPageShot() async throws {
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(try fixture("vh-page"))

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(image.height == (844 + 2000) * 2)
        let inHero = pixel(image, x: 390, y: 844 * 2 - 40)
        let belowHero = pixel(image, x: 390, y: 844 * 2 + 40)
        #expect(isClose(inHero, to: [255, 0, 0]), "hero pixel \(inHero)")
        #expect(isClose(belowHero, to: [0, 0, 255]), "below-hero pixel \(belowHero)")
        #expect(!snapshot.domHTML.contains("sharesheet-hid"))
    }

    /// Pages with `scroll-behavior: smooth` animate `scrollTo`, so a shot taken right after it lands mid-scroll.
    @Test func smoothScrollingPageIsStitchedInPlace() async throws {
        let capturer = WebPageCapturer()

        let snapshot = try await capturer.capture(try fixture("smooth-page"))

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(image.height == 3600 * 2)
        let colours: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255]]
        for band in 0..<9 {
            let expected = colours[band % 3]
            for y in [band * 400 + 30, band * 400 + 200, band * 400 + 370] {
                let actual = pixel(image, x: 390, y: y * 2)
                #expect(isClose(actual, to: expected), "pixel at \(y) pt is \(actual), expected \(expected)")
            }
        }
    }

    /// Embedded posts arrive as iframes after load; the shot waits until they are drawn.
    @Test func markupIsRenderedOnceItsEmbedIsDrawn() async throws {
        let capturer = WebPageCapturer()
        let html = """
            <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body { margin: 0; } iframe { display: block; width: 100%; height: 600px; border: 0; }</style></head>
            <body><script>
            setTimeout(function () {
              var f = document.createElement('iframe');
              f.srcdoc = '<body style="margin:0;background:#00f"></body>';
              document.body.appendChild(f);
            }, 800);
            </script></body></html>
            """

        let snapshot = try await capturer.capture(html: html, baseURL: URL(string: "https://example.com/post")!)

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(snapshot.finalURL == URL(string: "https://example.com/post"))
        // As tall as the post, not padded to a full screen.
        #expect(image.height == 600 * 2)
        let middle = pixel(image, x: 390, y: 600)
        #expect(isClose(middle, to: [0, 0, 255]), "embed pixel \(middle)")
    }

    /// A page with its own dark styles is captured twice; the first shot is light whatever the system uses.
    @Test func pageWithDarkStylesIsAlsoCapturedDark() async throws {
        let capturer = WebPageCapturer()
        _ = try await capturer.capture(try fixture("color-page"))
        capturer.hostWindow?.overrideUserInterfaceStyle = .dark

        let snapshot = try await capturer.capture(try fixture("dark-page"))

        let light = try #require(UIImage(data: snapshot.png)?.cgImage)
        let dark = try #require(snapshot.pngDark.flatMap { UIImage(data: $0)?.cgImage })
        #expect(isClose(pixel(light, x: 390, y: 400), to: [255, 255, 255]), "light \(pixel(light, x: 390, y: 400))")
        #expect(isClose(pixel(dark, x: 390, y: 400), to: [0, 0, 0]), "dark \(pixel(dark, x: 390, y: 400))")
        #expect(dark.height == light.height)
    }

    @Test func pageWithoutDarkStylesGetsNoDarkShot() async throws {
        let snapshot = try await WebPageCapturer().capture(try fixture("color-page"))
        #expect(snapshot.pngDark == nil)
    }

    /// Cookie banners, their backdrop and the scroll lock they set are gone before the shot; nothing is accepted.
    @Test func consentBannerIsRemovedBeforeCapture() async throws {
        let snapshot = try await WebPageCapturer().capture(try fixture("consent-page"))

        let image = try #require(UIImage(data: snapshot.png)?.cgImage)
        #expect(image.height == (40 + 3000) * 2)
        for y in [100, 400, 700, 800, 1500, 2900] {
            let actual = pixel(image, x: 390, y: y * 2)
            #expect(isClose(actual, to: [0, 255, 0]), "pixel at \(y) pt is \(actual)")
        }
        #expect(!snapshot.domHTML.contains("id=\"cookie-banner\""))
        #expect(!snapshot.domHTML.contains("onetrust-consent-sdk"))
        #expect(!snapshot.domHTML.contains("id=\"shadow-consent\""))
        #expect(!snapshot.domHTML.contains("id=\"backdrop\""))
        // Ordinary content and a sticky header that only mention the words stay.
        #expect(snapshot.domHTML.contains("id=\"recipe\""))
        #expect(snapshot.domHTML.contains("id=\"site-header\""))
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
