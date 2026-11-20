import InstagramMedia
import SwiftUI
import WebKit

/// Holds Instagram's own login page and reads the resulting cookies. The password never reaches the app.
@MainActor
@Observable
final class InstagramLoginModel {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))
    }

    func readSession() async -> InstagramSession? {
        let cookies = await Self.cookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        let instagram = cookies.filter { $0.domain.contains("instagram.com") }
        guard instagram.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        return InstagramSession(cookies: instagram.map {
            .init(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                expires: $0.expiresDate, secure: $0.isSecure)
        })
    }

    static func clearWebCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookies(in: store) where cookie.domain.contains("instagram.com") {
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    private static func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
struct InstagramLoginView: View {
    var onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = InstagramLoginModel()
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                InstagramWebView(webView: model.webView)
                Text("Sign in through Instagram. The app keeps only the session cookies in the keychain; your password is never seen. Instagram’s terms apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .navigationTitle("Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await finish() } }
                }
            }
            .alert("Sign in first", isPresented: $problem.isPresent()) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    private func finish() async {
        guard let session = await model.readSession() else {
            problem = "Sign in to Instagram first."
            return
        }
        guard InstagramSessionStore.shared.save(session) else {
            problem = "The session couldn’t be saved."
            return
        }
        onSignedIn()
        dismiss()
    }
}

private struct InstagramWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
