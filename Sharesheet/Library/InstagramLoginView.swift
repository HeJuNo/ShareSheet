import InstagramMedia
import SwiftUI

struct InstagramLoginView: View {
    var onSignedIn: () -> Void

    var body: some View {
        WebLoginView(
            url: URL(string: "https://www.instagram.com/accounts/login/")!,
            serviceName: "Instagram",
            cookieDomains: ["instagram.com"],
            requiredCookie: "sessionid",
            save: { InstagramSessionStore.shared.save($0) },
            onSignedIn: onSignedIn)
    }
}
