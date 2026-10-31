import UIKit
import WebKit

struct PageSnapshot: Sendable {
    var png: Data
    var domHTML: String
    var finalURL: URL
    var iconURL: URL?
    var truncated: Bool
}

protocol PageCapturing: Sendable {
    @MainActor func capture(_ url: URL) async throws -> PageSnapshot
}

enum CaptureError: Error {
    case timeout, loadFailed(String)
}

/// Loads a page in an off-screen web view, scrolls it to trigger lazy content and takes a full-page snapshot.
@MainActor
final class WebPageCapturer: PageCapturing {
    private let width: CGFloat
    private let scale: CGFloat
    private let loadTimeout: Duration
    private let maxHeight: CGFloat
    private let viewportHeight: CGFloat = 844
    private var window: UIWindow?

    init(width: CGFloat = 390, scale: CGFloat = 2, loadTimeout: Duration = .seconds(30), maxHeight: CGFloat = 20_000) {
        self.width = width
        self.scale = scale
        self.loadTimeout = loadTimeout
        self.maxHeight = maxHeight
    }

    func capture(_ url: URL) async throws -> PageSnapshot {
        let window = hostWindow()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight), configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        window.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        let loader = PageLoader()
        webView.navigationDelegate = loader
        try await Self.withTimeout(loadTimeout) {
            try await loader.load(url, in: webView)
        }

        let fullHeight = try await scrollThrough(webView)
        let height = min(fullHeight, maxHeight)
        webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        webView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let screenScale = window.traitCollection.displayScale > 0 ? window.traitCollection.displayScale : UIScreen.main.scale
        snapshotConfig.snapshotWidth = NSNumber(value: Double(width * scale / screenScale))
        let image = try await webView.takeSnapshot(configuration: snapshotConfig)
        guard let png = image.pngData() else { throw CaptureError.loadFailed("snapshot could not be encoded") }

        let dom = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        let icon = try? await webView.evaluateJavaScript(
            "(function(){ var l = document.querySelector('link[rel~=icon]'); return l ? l.href : null; })()") as? String
        return PageSnapshot(
            png: png, domHTML: dom, finalURL: webView.url ?? url,
            iconURL: icon.flatMap { $0.isEmpty ? nil : URL(string: $0) }, truncated: fullHeight > maxHeight)
    }

    /// Scrolls down one viewport every 150 ms until the document stops growing or reaches `maxHeight`,
    /// then returns to the top. Returns the final scroll height.
    private func scrollThrough(_ webView: WKWebView) async throws -> CGFloat {
        var height = try await scrollHeight(webView)
        var offset: CGFloat = 0
        let maxSteps = Int(maxHeight / viewportHeight) + 2
        for _ in 0..<maxSteps where height < maxHeight {
            try Task.checkCancellation()
            offset += viewportHeight
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(Int(offset)))")
            try await Task.sleep(for: .milliseconds(150))
            let newHeight = try await scrollHeight(webView)
            let grew = newHeight > height
            height = newHeight
            if !grew, offset + viewportHeight >= height { break }
        }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0)")
        try await Task.sleep(for: .milliseconds(500))
        return max(height, 1)
    }

    private func scrollHeight(_ webView: WKWebView) async throws -> CGFloat {
        let value = try await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        return CGFloat((value as? NSNumber)?.doubleValue ?? 0)
    }

    /// A window behind the app's own window: web content only renders and lazy-loads inside a visible window hierarchy.
    private func hostWindow() -> UIWindow {
        if let window { return window }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        window.isHidden = false
        self.window = window
        return window
    }

    /// Runs `operation`, throwing `CaptureError.timeout` (and cancelling it) when it takes longer than `duration`.
    private nonisolated static func withTimeout(
        _ duration: Duration, _ operation: @escaping @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CaptureError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

/// Bridges `WKNavigationDelegate` callbacks for one top-level load to async/await.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private weak var webView: WKWebView?

    func load(_ url: URL, in webView: WKWebView) async throws {
        self.webView = webView
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                if url.isFileURL {
                    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.webView?.stopLoading()
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(CaptureError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(CaptureError.loadFailed(error.localizedDescription)))
    }
}
