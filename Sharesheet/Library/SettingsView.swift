import FoundationModels
import InstagramMedia
import SwiftUI

/// iCloud status, index and capture maintenance, and the app version.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isRebuilding = false
    @State private var confirmsAnalyzeAgain = false
    @State private var signedIn = Dictionary(
        uniqueKeysWithValues: AccountService.allCases.map {
            ($0, $0.store.load()?.isUsable(requiredCookie: $0.requiredCookie) ?? false)
        })
    @State private var loginService: AccountService?
    @State private var confirmingSignOut: AccountService?
    @AppStorage(AnalysisSettings.enabledKey) private var analyzeDocuments = AnalysisSettings.defaultEnabled
    @AppStorage(AnalysisSettings.tagModeKey) private var tagMode = AnalysisSettings.defaultTagMode.rawValue
    @AppStorage(TrashSettings.autoEmptyKey) private var trashAutoEmpty = TrashSettings.defaultAutoEmpty
    @AppStorage(TrashSettings.daysKey) private var trashDays = TrashSettings.defaultDays

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
                    ForEach(AccountService.allCases) { service in
                        accountRow(service)
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Private or protected posts need a signed-in session. The cookies stay in the keychain; the service’s terms apply.")
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
                        model.startCaptures()
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
            .sheet(item: $loginService) { service in
                service.loginView { signedIn[service] = true }
            }
            .confirmationDialog(
                "Sign out of \(confirmingSignOut?.name ?? "")?",
                isPresented: $confirmingSignOut.isPresent(),
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    if let service = confirmingSignOut { signOut(service) }
                }
                Button("Cancel", role: .cancel) { confirmingSignOut = nil }
            } message: {
                Text("Private posts need the session; you will have to sign in again.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The whole row is the control, so its target is at least 44 pt; narrow widths stack the action below.
    private func accountRow(_ service: AccountService) -> some View {
        let connected = signedIn[service] == true
        return Button {
            if connected {
                confirmingSignOut = service
            } else {
                loginService = service
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(service.name)
                    Spacer(minLength: 8)
                    if connected {
                        Text("Connected").foregroundStyle(.secondary)
                        Text("Sign out").foregroundStyle(.red)
                    } else {
                        Text("Connect").foregroundStyle(Color.accentColor)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(service.name)
                        Spacer(minLength: 8)
                        if connected { Text("Connected").foregroundStyle(.secondary) }
                    }
                    Text(connected ? "Sign out" : "Connect")
                        .foregroundStyle(connected ? Color.red : Color.accentColor)
                }
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(connected ? "Sign out of \(service.name)" : "Connect \(service.name)"))
        .accessibilityValue(Text(connected ? "Connected" : "Not connected"))
    }

    private func signOut(_ service: AccountService) {
        service.store.clear()
        signedIn[service] = false
        Task {
            for domain in service.cookieDomains {
                await WebLoginModel.clearWebCookies(domain: domain)
            }
        }
    }

    /// A login service: its keychain entry, the cookies that mean "signed in", and its web sheet.
    private enum AccountService: String, CaseIterable, Identifiable {
        case instagram, x

        var id: String { rawValue }

        var name: String {
            switch self {
            case .instagram: "Instagram"
            case .x: "X"
            }
        }

        var requiredCookie: String {
            switch self {
            case .instagram: "sessionid"
            case .x: "auth_token"
            }
        }

        var cookieDomains: [String] {
            switch self {
            case .instagram: ["instagram.com"]
            case .x: ["x.com", "twitter.com"]
            }
        }

        var store: WebSessionStore {
            switch self {
            case .instagram: InstagramSessionStore.shared
            case .x: WebSessionStore.x
            }
        }

        @MainActor
        @ViewBuilder
        func loginView(onSignedIn: @escaping () -> Void) -> some View {
            switch self {
            case .instagram: InstagramLoginView(onSignedIn: onSignedIn)
            case .x: XLoginView(onSignedIn: onSignedIn)
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
