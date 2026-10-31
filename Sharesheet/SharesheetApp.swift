import SwiftUI

@main
struct SharesheetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
    /// Set when the app went to the background, so returning to it refreshes once (launch refreshes via `.task`).
    @State private var wasInBackground = false

    init() {
        BackgroundCapture.register {
            let model = await AppModel.shared
            await model.refreshAndCapture()
            if await model.pendingCaptureCount > 0 { BackgroundCapture.schedule() }
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
            case .active where wasInBackground:
                wasInBackground = false
                Task { await model.refresh() }
            case .background:
                wasInBackground = true
                if model.pendingCaptureCount > 0 { BackgroundCapture.schedule() }
            default:
                break
            }
        }
    }
}
