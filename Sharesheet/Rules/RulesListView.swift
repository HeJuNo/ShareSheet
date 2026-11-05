import SharesheetCore
import SwiftUI

/// The rules: switch them on and off, reorder, delete, add, and apply them to the items already in the library.
struct RulesListView: View {
    @State private var model: RulesModel
    @State private var editing: Rule?
    @State private var failure: String?
    @State private var confirmsNewFile = false
    @State private var preview: RulePreview?
    @State private var showsNothingToChange = false
    @State private var runTask: Task<Void, Never>?
    @State private var progress = 0
    @State private var total = 0
    @State private var lastResult: Int?

    init(model: RulesModel) { _model = State(initialValue: model) }

    private var hasUsableRule: Bool { model.rules.contains { $0.enabled && $0.isUsable } }

    var body: some View {
        List {
            switch model.state {
            case .loading:
                ProgressView()
            case .unavailable:
                Text("Rules are stored in the iCloud library, which isn’t available.")
                    .foregroundStyle(.secondary)
            case .blocked(let message):
                Section {
                    Text("The rules file can’t be read, so rules can’t be changed.")
                    Text(verbatim: message).font(.footnote).foregroundStyle(.red)
                    Button("Start a new rules file…") { confirmsNewFile = true }
                } footer: {
                    Text("The unreadable file is kept as rules.json.broken.")
                }
            case .ready:
                rulesSection
                applySection
            }
            if let failure {
                Section { Text(verbatim: failure).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("Rules")
        .toolbar {
            if model.state == .ready {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = Rule(
                            id: UUID().uuidString, name: "", enabled: true,
                            conditions: [RuleCondition(field: .url, op: .contains, value: "")], actions: [])
                    } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                }
            }
        }
        .task { await model.reload() }
        .sheet(item: $editing) { rule in
            NavigationStack { RuleEditorView(rule: rule) { await store($0) } }
        }
        .confirmationDialog("Start a new rules file?", isPresented: $confirmsNewFile, titleVisibility: .visible) {
            Button("Start new file", role: .destructive) { run { try await model.startNewFile() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file you wrote is kept as rules.json.broken.")
        }
        .confirmationDialog(
            "Apply the rules to existing items?", isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
            titleVisibility: .visible, presenting: preview
        ) { _ in
            Button("Apply") { startApplying() }
            Button("Cancel", role: .cancel) {}
        } message: { preview in
            Text("\(preview.items) items would change: \(preview.tagsAdded) tags added, \(preview.moved) moved, \(preview.dates) dates, \(preview.fields) fields and \(preview.titles) titles set.")
        }
        .alert("Nothing to change", isPresented: $showsNothingToChange) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No existing item matches a rule in a way that would change it.")
        }
    }

    private var rulesSection: some View {
        Section {
            if model.rules.isEmpty {
                Text("No rules yet. Add one with +.").foregroundStyle(.secondary)
            }
            ForEach(model.rules) { rule in
                HStack {
                    Button { editing = rule } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: rule.displayName).foregroundStyle(.primary)
                            if rule.isUsable {
                                Text(verbatim: rule.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Text("Incomplete, not applied").font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { rule.enabled }, set: { value in update(rule) { $0.enabled = value } }))
                        .labelsHidden()
                }
            }
            .onDelete { offsets in
                var rules = model.rules
                rules.remove(atOffsets: offsets)
                persist(rules)
            }
            .onMove { from, to in
                var rules = model.rules
                rules.move(fromOffsets: from, toOffset: to)
                persist(rules)
            }
        } footer: {
            Text("Rules only add tags, and only move items out of Unsorted.")
        }
    }

    private var applySection: some View {
        Section {
            if runTask != nil {
                HStack {
                    ProgressView(value: Double(progress), total: Double(max(total, 1)))
                    Button("Stop") { runTask?.cancel() }
                }
            } else {
                Button("Apply to existing items…") {
                    Task {
                        guard let result = await model.preview() else { return }
                        if result.items == 0 { showsNothingToChange = true } else { preview = result }
                    }
                }
                .disabled(!hasUsableRule)
            }
            if let lastResult, runTask == nil {
                Text("\(lastResult) items changed.").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Rules on document text only apply to documents that were analyzed.")
        }
    }

    private func startApplying() {
        total = model.itemCount
        progress = 0
        lastResult = nil
        runTask = Task {
            let changed = await model.applyAll { done in Task { @MainActor in progress = done } }
            lastResult = changed
            runTask = nil
        }
    }

    private func update(_ rule: Rule, _ change: (inout Rule) -> Void) {
        var rules = model.rules
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&rules[index])
        persist(rules)
    }

    private func persist(_ rules: [Rule]) {
        run { try await model.save(rules) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                failure = nil
            } catch {
                failure = "The rules couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Adds or replaces a rule from the editor; an error text, nil on success.
    private func store(_ edited: Rule) async -> String? {
        var rule = edited
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.derivedName }
        var rules = model.rules
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        do {
            try await model.save(rules)
            return nil
        } catch {
            return "The rule couldn’t be saved: \(error.localizedDescription)"
        }
    }
}

extension Rule {
    /// "Tag apple" or "Move to Tech", from the first action.
    var derivedName: String {
        switch actions.first {
        case .addTag(let tag): "Tag \(tag)"
        case .moveTo(let collection): "Move to \(collection)"
        case .setDate: "Set date from text"
        case .setField(let name, _): "Set \(name)"
        case .setTitle: "Set title"
        case nil: "Rule"
        }
    }

    var displayName: String { name.isEmpty ? derivedName : name }

    /// "type is link, url contains apple.com → tag apple".
    var summary: String {
        let joiner = match == .all ? " and " : " or "
        let conditions = self.conditions.map { "\($0.field.rawValue) \($0.op.rawValue) \($0.value)" }.joined(separator: joiner)
        let actions = self.actions.map { action -> String in
            switch action {
            case .addTag(let tag): "tag \(tag)"
            case .moveTo(let collection): "move to \(collection)"
            case .setDate(let pattern): "set date from “\(pattern)”"
            case .setField(let name, let pattern): "set \(name) from “\(pattern)”"
            case .setTitle(let template): "set title “\(template)”"
            }
        }.joined(separator: ", ")
        return "\(conditions) → \(actions)"
    }
}
