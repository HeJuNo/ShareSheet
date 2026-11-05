import SharesheetCore
import SwiftUI

/// Edits one rule: name, conditions (all or any must hold) and actions.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    @State private var failure: String?
    @State private var isSaving = false
    /// Saves the rule; returns an error text, nil on success.
    private let save: (Rule) async -> String?

    init(rule: Rule, save: @escaping (Rule) async -> String?) {
        _rule = State(initialValue: rule)
        self.save = save
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
            }
            Section {
                if rule.conditions.count > 1 {
                    Picker("Match", selection: $rule.match) {
                        Text("All conditions").tag(RuleMatch.all)
                        Text("At least one condition").tag(RuleMatch.any)
                    }
                }
                ForEach(rule.conditions.indices, id: \.self) { index in
                    ConditionRow(condition: $rule.conditions[index])
                }
                .onDelete { rule.conditions.remove(atOffsets: $0) }
                Button {
                    rule.conditions.append(RuleCondition(field: .url, op: .contains, value: ""))
                } label: {
                    Label("Add condition", systemImage: "plus")
                }
            } header: {
                Text("If")
            }
            Section {
                ForEach(rule.actions.indices, id: \.self) { index in
                    ActionRow(action: $rule.actions[index], tags: app.tags, collections: app.collections.map(\.relativePath))
                }
                .onDelete { rule.actions.remove(atOffsets: $0) }
                Button {
                    rule.actions.append(.addTag(""))
                } label: {
                    Label("Add action", systemImage: "plus")
                }
            } header: {
                Text("Then")
            } footer: {
                Text("Tags are only added, and items are only moved out of Unsorted.")
            }
            if !rule.isUsable {
                Section {
                    Label("Add a value to every condition and at least one action.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            if let failure {
                Section { Text(verbatim: failure).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(rule.name.isEmpty ? Text("Rule") : Text(verbatim: rule.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    isSaving = true
                    Task {
                        failure = await save(rule)
                        isSaving = false
                        if failure == nil { dismiss() }
                    }
                }
                .disabled(!rule.isUsable || isSaving)
            }
        }
    }
}

private struct ConditionRow: View {
    @Binding var condition: RuleCondition

    private static let labels: [RuleField: LocalizedStringKey] = [
        .type: "Type", .url: "URL", .domain: "Domain", .title: "Title", .note: "Note", .text: "Text", .tag: "Tag",
    ]

    /// Type and tag are matched exactly; the other fields can also be searched.
    private var operators: [RuleOperator] {
        condition.field == .type || condition.field == .tag ? [.is] : [.contains, .is]
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Field", selection: $condition.field) {
                    ForEach([RuleField.type, .url, .domain, .title, .note, .text, .tag], id: \.self) { field in
                        Text(Self.labels[field] ?? "").tag(field)
                    }
                }
                .labelsHidden()
                Picker("Operator", selection: $condition.op) {
                    ForEach(operators, id: \.self) { op in
                        Text(op == .is ? "is" : "contains").tag(op)
                    }
                }
                .labelsHidden()
            }
            if condition.field == .type {
                Picker("Type", selection: $condition.value) {
                    Text("Choose…").tag("")
                    ForEach(ItemType.allCases, id: \.self) { type in
                        Text(type.label).tag(type.rawValue)
                    }
                }
            } else {
                TextField("Value", text: $condition.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .onChange(of: condition.field) { _, field in
            if !operators.contains(condition.op) { condition.op = .is }
            if field == .type, ItemType(rawValue: condition.value) == nil { condition.value = "" }
        }
    }
}

private struct ActionRow: View {
    @Binding var action: RuleAction
    let tags: [String]
    let collections: [String]

    private var isMove: Binding<Bool> {
        Binding(
            get: { if case .moveTo = action { true } else { false } },
            set: { move in action = move ? .moveTo(text.wrappedValue) : .addTag(text.wrappedValue) })
    }

    private var text: Binding<String> {
        Binding(
            get: {
                switch action {
                case .addTag(let value), .moveTo(let value): value
                }
            },
            set: { value in
                switch action {
                case .addTag: action = .addTag(value)
                case .moveTo: action = .moveTo(value)
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Action", selection: isMove) {
                Text("Add tag").tag(false)
                Text("Move to collection").tag(true)
            }
            HStack {
                TextField(isMove.wrappedValue ? "Collection" : "Tag", text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let suggestions = isMove.wrappedValue ? collections : tags
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions.prefix(40), id: \.self) { name in
                            Button(name) { text.wrappedValue = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .accessibilityLabel(Text("Choose existing"))
                }
            }
        }
    }
}
