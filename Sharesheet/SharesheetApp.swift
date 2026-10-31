import SwiftUI

@main
struct SharesheetApp: App {
    init() {
        BackgroundCapture.register {}
    }

    var body: some Scene {
        WindowGroup {
            Text("Sharesheet")
        }
    }
}
