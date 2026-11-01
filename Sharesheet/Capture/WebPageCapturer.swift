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

enum CaptureError: Error, Equatable {
    case timeout, loadFailed(String)
    /// A failed navigation in `NSURLErrorDomain`, with its code (offline, host not found, ...).
    case network(Int)
}

/// Loads a page in an off-screen web view, scrolls it to trigger lazy content and takes a full-page snapshot.
/// The load is bounded by `loadTimeout`, everything after it (scrolling, snapshot, DOM reads) by `postLoadBudget`.
@MainActor
final class WebPageCapturer: PageCapturing {
    private let width: CGFloat
    private let scale: CGFloat
    private let loadTimeout: Duration
    private let postLoadBudget: Duration
    private let maxHeight: CGFloat
    private let viewportHeight: CGFloat = 844
    /// The window web views are hosted in; created on first capture.
    private(set) var hostWindow: UIWindow?

    init(
        width: CGFloat = 390, scale: CGFloat = 2, loadTimeout: Duration = .seconds(30), maxHeight: CGFloat = 20_000,
        postLoadBudget: Duration = .seconds(30)
    ) {
        self.width = width
        self.scale = scale
        self.loadTimeout = loadTimeout
        self.postLoadBudget = postLoadBudget
        self.maxHeight = maxHeight
    }

    func capture(_ url: URL) async throws -> PageSnapshot {
        let window = resolveHostWindow()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight), configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityElementsHidden = true
        window.addSubview(webView)
        let loader = PageLoader()
        webView.navigationDelegate = loader
        // Runs as soon as the bounded race returns, even if a WebKit call is still stuck in the abandoned work.
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        let terminated = CaptureError.loadFailed("web content process terminated")
        try await Self.bounded(loadTimeout) { fail in
            loader.onTerminate = { fail(terminated) }
            try await loader.load(url, in: webView)
        }
        return try await Self.bounded(postLoadBudget) { [self] fail in
            loader.onTerminate = { fail(terminated) }
            return try await render(webView, in: window, url: url)
        }
    }

    private func render(_ webView: WKWebView, in window: UIWindow, url: URL) async throws -> PageSnapshot {
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
        try Task.checkCancellation()

        let dom = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let value = try await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        return CGFloat((value as? NSNumber)?.doubleValue ?? 0)
    }

    /// A window behind the app's own window: web content only renders and lazy-loads inside a visible window
    /// hierarchy. Follows the foreground scene on every capture; standalone only when there is no scene.
    private func resolveHostWindow() -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        if let window = hostWindow {
            if let scene, window.windowScene !== scene { window.windowScene = scene }
            return window
        }
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.isHidden = false
        hostWindow = window
        return window
    }

    /// Runs `operation` and returns as soon as it finishes, `duration` passes (`CaptureError.timeout`), the caller
    /// is cancelled, or the operation calls its `fail` callback. The losing work is cancelled but never awaited,
    /// so a WebKit call that ignores cancellation cannot block the caller.
    private nonisolated static func bounded<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable @MainActor (_ fail: @escaping @Sendable (any Error) -> Void) async throws -> T
    ) async throws -> T {
        let outcome = Outcome<T>()
        let work = Task { @MainActor in
            do {
                outcome.resolve(.success(try await operation { outcome.resolve(.failure($0)) }))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { outcome.resolve(.failure(CaptureError.timeout)) }
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            outcome.resolve(.failure(CancellationError()))
        }
    }
}

/// The first result wins; later ones are ignored.
private final class Outcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    func resolve(_ value: Result<T, any Error>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            continuation?.resume(with: value)
            continuation = nil
        }
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result { continuation.resume(with: result) } else { self.continuation = continuation }
            }
        }
    }
}

/// Bridges `WKNavigationDelegate` callbacks for one top-level load to async/await.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    var onTerminate: (() -> Void)?
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

    /// A navigation cancelled by a newer one (redirects, `location` changes) is not a failure: keep waiting.
    private func fail(_ error: any Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        finish(.failure(ns.domain == NSURLErrorDomain ? CaptureError.network(ns.code) : CaptureError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(CaptureError.loadFailed("web content process terminated")))
        onTerminate?()
    }
}
