import FoundationModels
import SwiftUI

/// iCloud status, index and capture maintenance, and the app version.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isRebuilding = false
    @State private var confirmsAnalyzeAgain = false
    @AppStorage(AnalysisSettings.enabledKey) private var analyzeDocuments = true
    @AppStorage(AnalysisSettings.tagModeKey) private var tagMode = TagMode.suggest.rawValue
    @AppStorage(TrashSettings.autoEmptyKey) private var trashAutoEmpty = true
    @AppStorage(TrashSettings.daysKey) private var trashDays = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        switch model.iCloudState {
                        case .unknown: Text("Checking…")
                        case .available: Text("Available")
                        case .unavailable: Text("Unavailable")
                        }
                    } label: {
                        Label("iCloud Drive", systemImage: model.iCloudState == .unavailable ? "icloud.slash" : "icloud")
                    }
                    if model.lastImportProblemCount > 0 {
                        Label("Shares not imported: \(model.lastImportProblemCount)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
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
                    Button("Retry failed captures (\(model.failedCaptureCount))") {
                        Task { await model.retryFailedCaptures() }
                    }
                    .disabled(model.failedCaptureCount == 0 || !model.isICloudAvailable)
                }
                Section {
                    Toggle("Empty Trash automatically", isOn: $trashAutoEmpty)
                    Picker("Delete after", selection: $trashDays) {
                        ForEach(TrashSettings.dayChoices, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .disabled(!trashAutoEmpty)
                } header: {
                    Text("Trash")
                } footer: {
                    Text(trashAutoEmpty
                        ? "Deleted items are removed for good after this time."
                        : "Deleted items stay in the Trash until you remove them.")
                }
                Section {
                    NavigationLink("Rules") { RulesListView(model: model.makeRulesModel()) }
                }
                Section {
                    Toggle("Analyze documents", isOn: $analyzeDocuments)
                    Picker("Tags", selection: $tagMode) {
                        Text("Off").tag(TagMode.off.rawValue)
                        Text("Set automatically").tag(TagMode.automatic.rawValue)
                        Text("Suggest").tag(TagMode.suggest.rawValue)
                    }
                    .disabled(!analyzeDocuments)
                    if SystemLanguageModel.default.availability != .available {
                        Text("Without Apple Intelligence, tags are matched against your tagged documents and a few common kinds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let problem = model.rulesStatus.problem {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The rules file is invalid, so no rules are applied.")
                            Text(verbatim: problem)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                    Button("Analyze all again") { confirmsAnalyzeAgain = true }
                        .disabled(!analyzeDocuments || !model.isICloudAvailable)
                        .confirmationDialog(
                            "Analyze all documents again?", isPresented: $confirmsAnalyzeAgain, titleVisibility: .visible
                        ) {
                            Button("Analyze") { model.analyzeAgain() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Keywords are recalculated. In automatic mode, tags you removed may be set again.")
                        }
                } header: {
                    Text("Documents")
                } footer: {
                    Text("Keywords improve search. Tags name the kind of document, for example Invoice or Statement. Everything stays on this iPhone.")
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
