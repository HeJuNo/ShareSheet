import BackgroundTasks
import Foundation

/// Runs pending captures in a `BGProcessingTask`.
enum BackgroundCapture {
    /// Listed in Info.plist's BGTaskSchedulerPermittedIdentifiers as `$(PRODUCT_BUNDLE_IDENTIFIER).capture`.
    static let identifier = "\(Bundle.main.bundleIdentifier ?? "Sharesheet").capture"

    /// Must be called before the app finishes launching.
    static func register(runner: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let box = TaskBox(task: task)
            let work = Task {
                await runner()
                box.task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// `BGTask` is thread-safe for completion but not marked `Sendable`.
private struct TaskBox: @unchecked Sendable {
    let task: BGTask
}
