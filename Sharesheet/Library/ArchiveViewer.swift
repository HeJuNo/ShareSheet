import SwiftUI
import UIKit
import WebKit

/// The saved HTML archive of a page, offline: scripts off, nothing stored, read access limited to the file.
/// Only the archive itself loads; tapped web links open in Safari, every other navigation is cancelled.
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

/// What the archive web view may do with a navigation.
enum ArchiveNavigation: Equatable {
    case allow, openExternally, cancel

    /// Only the archive file itself loads (in-page `#anchors` included); a tapped http(s) link opens outside,
    /// anything else (other files in `_attachments`, other schemes) is refused.
    static func decide(_ target: URL?, archive: URL, isLinkActivated: Bool) -> ArchiveNavigation {
        guard let target else { return .cancel }
        if target.isFileURL {
            return target.standardizedFileURL.path == archive.standardizedFileURL.path ? .allow : .cancel
        }
        if isLinkActivated, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .openExternally
        }
        return .cancel
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(archive: url) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadFileURL(url, allowingReadAccessTo: url)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let archive: URL

        init(archive: URL) {
            self.archive = archive
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let target = navigationAction.request.url
            switch ArchiveNavigation.decide(
                target, archive: archive, isLinkActivated: navigationAction.navigationType == .linkActivated)
            {
            case .allow:
                return .allow
            case .openExternally:
                if let target { await UIApplication.shared.open(target) }
                return .cancel
            case .cancel:
                return .cancel
            }
        }
    }
}
