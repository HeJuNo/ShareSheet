import SwiftUI

/// iCloud status, index and capture maintenance, and the app version.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isRebuilding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(model.isICloudAvailable ? "Available" : "Unavailable")
                    } label: {
                        Label("iCloud Drive", systemImage: model.isICloudAvailable ? "icloud" : "icloud.slash")
                    }
                }
                Section {
                    Button {
                        Task {
                            isRebuilding = true
                            await model.rebuildIndex()
                            isRebuilding = false
                        }
                    } label: {
                        HStack {
                            Text("Rebuild index")
                            if isRebuilding {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRebuilding || !model.isICloudAvailable)
                    Button("Capture pending now (\(model.pendingCaptureCount))") {
                        model.capturePendingNow()
                    }
                    .disabled(model.pendingCaptureCount == 0 || !model.isICloudAvailable)
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
