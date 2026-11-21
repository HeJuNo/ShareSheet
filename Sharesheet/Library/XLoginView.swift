import SharesheetCore
import SwiftUI

struct XLoginView: View {
    var onSignedIn: () -> Void

    var body: some View {
        WebLoginView(
            url: URL(string: "https://x.com/i/flow/login")!,
            serviceName: "X",
            cookieDomains: ["x.com", "twitter.com"],
            requiredCookie: "auth_token",
            save: { WebSessionStore.x.save($0) },
            onSignedIn: onSignedIn)
    }
}
