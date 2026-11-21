import SharesheetCore
import SwiftUI
import WebKit

/// Holds a service's own login page and reads the resulting cookies. The password never reaches the app.
@MainActor
@Observable
final class WebLoginModel {
    let webView: WKWebView

    init(url: URL) {
        webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        webView.load(URLRequest(url: url))
    }

    /// The login page keeps its cookies in memory only; the keychain is the one persistent copy.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    func readSession(domains: [String], requiredCookie: String) async -> WebSession? {
        let cookies = await Self.cookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        let matching = cookies.filter { cookie in
            domains.contains { Self.matches(cookie.domain, $0) }
        }
        guard matching.contains(where: { $0.name == requiredCookie && !$0.value.isEmpty }) else { return nil }
        return WebSession(cookies: matching.map {
            .init(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                expires: $0.expiresDate, secure: $0.isSecure)
        })
    }

    static func clearWebCookies(domain: String) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookies(in: store) where matches(cookie.domain, domain) {
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    private static func matches(_ cookieDomain: String, _ domain: String) -> Bool {
        let cookie = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let target = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cookie == target || cookie.hasSuffix("." + target)
    }

    private static func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

/// The login sheet for a web service, with a non-persistent store and a keychain save step.
@MainActor
struct WebLoginView: View {
    let url: URL
    let serviceName: String
    let cookieDomains: [String]
    let requiredCookie: String
    let save: @MainActor (WebSession) -> Bool
    var onSignedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: WebLoginModel
    @State private var problem: String?

    init(
        url: URL, serviceName: String, cookieDomains: [String], requiredCookie: String,
        save: @escaping @MainActor (WebSession) -> Bool, onSignedIn: @escaping () -> Void
    ) {
        self.url = url
        self.serviceName = serviceName
        self.cookieDomains = cookieDomains
        self.requiredCookie = requiredCookie
        self.save = save
        self.onSignedIn = onSignedIn
        _model = State(initialValue: WebLoginModel(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebLoginWebView(webView: model.webView)
                Text("Sign in through \(serviceName). The app keeps only the session cookies in the keychain; your password is never seen. \(serviceName)’s terms apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .navigationTitle(serviceName)
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
        guard let session = await model.readSession(domains: cookieDomains, requiredCookie: requiredCookie) else {
            problem = "Sign in to \(serviceName) first."
            return
        }
        guard save(session) else {
            problem = "The session couldn’t be saved."
            return
        }
        onSignedIn()
        dismiss()
    }
}

private struct WebLoginWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Instagram's login wrapper; the shared view does the work.
typealias InstagramLoginModel = WebLoginModel
