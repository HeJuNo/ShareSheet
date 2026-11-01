import SwiftUI
import UIKit
import WebKit

/// The saved HTML archive of a page, offline: scripts off, nothing stored, read access limited to its folder.
/// Tapped links open in Safari.
struct ArchiveViewer: View {
    let relativePath: String
    @Environment(AppModel.self) private var model
    @State private var url: URL?
    @State private var resolved = false

    var body: some View {
        Group {
            if let url {
                ArchiveWebView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if resolved {
                ContentUnavailableView("File missing", systemImage: "doc.richtext")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: relativePath) {
            url = await model.attachmentURL(relativePath)
            resolved = true
        }
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let target = navigationAction.request.url,
                !target.isFileURL
            else { return .allow }
            await UIApplication.shared.open(target)
            return .cancel
        }
    }
}
