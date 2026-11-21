import SharesheetCore
import SwiftUI

struct FacebookLoginView: View {
    var onSignedIn: () -> Void

    var body: some View {
        WebLoginView(
            url: URL(string: "https://m.facebook.com/login/")!,
            serviceName: "Facebook",
            cookieDomains: ["facebook.com"],
            requiredCookie: "c_user",
            save: { WebSessionStore.facebook.save($0) },
            onSignedIn: onSignedIn)
    }
}
