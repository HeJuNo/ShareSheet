import SwiftUI

@main
struct SharesheetApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    init() {
        BackgroundCapture.register {
            let model = await AppModel.shared
            await model.refreshAndCapture()
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
                Task { await model.refresh() }
            case .background where model.pendingCaptureCount > 0:
                BackgroundCapture.schedule()
            default:
                break
            }
        }
    }
}
