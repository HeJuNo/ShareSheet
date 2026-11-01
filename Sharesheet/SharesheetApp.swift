import SharesheetCore
import SwiftUI
import UIKit

@main
struct SharesheetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
    /// Set when the app went to the background, so returning to it refreshes once (launch refreshes via `.task`).
    @State private var wasInBackground = false

    init() {
        BackgroundCapture.register {
            LibraryIndex.resume()
            let model = await AppModel.shared
            await model.refreshAndCapture()
            if await model.pendingCaptureCount > 0 { BackgroundCapture.schedule() }
            // The app may have come to the foreground meanwhile; then the scene keeps the index running.
            if await UIApplication.shared.applicationState != .active { LibraryIndex.suspend() }
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .task { await model.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                LibraryIndex.resume()
                guard wasInBackground else { break }
                wasInBackground = false
                Task { await model.refresh() }
            case .background:
                wasInBackground = true
                // Always: the background run imports shares made meanwhile before capturing.
                BackgroundCapture.schedule()
                LibraryIndex.suspend()
            default:
                break
            }
        }
    }
}
