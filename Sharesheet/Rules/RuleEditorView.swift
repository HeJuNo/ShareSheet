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

    private enum Kind: Hashable { case tag, move, date, field, computed, title }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch action {
                case .addTag: .tag
                case .moveTo: .move
                case .setDate: .date
                case .setField: .field
                case .setComputed: .computed
                case .setTitle: .title
                }
            },
            set: { new in
                let value = text.wrappedValue
                switch new {
                case .tag: action = .addTag(value)
                case .move: action = .moveTo(value)
                case .date: action = .setDate(value)
                case .field: action = .setField(name: "", pattern: value)
                case .computed: action = .setComputed(name: "", formula: value)
                case .title: action = .setTitle(value)
                }
            })
    }

    private var text: Binding<String> {
        Binding(
            get: {
                switch action {
                case .addTag(let value), .moveTo(let value), .setDate(let value), .setTitle(let value): value
                case .setField(_, let pattern, _, _, _): pattern
                case .setComputed(_, let formula, _): formula
                }
            },
            set: { value in
                switch action {
                case .addTag: action = .addTag(value)
                case .moveTo: action = .moveTo(value)
                case .setDate: action = .setDate(value)
                case .setField(let name, _, let aggregate, let op, let operand):
                    action = .setField(name: name, pattern: value, aggregate: aggregate, op: op, operand: operand)
                case .setComputed(let name, _, let aggregate): action = .setComputed(name: name, formula: value, aggregate: aggregate)
                case .setTitle: action = .setTitle(value)
                }
            })
    }

    private var fieldName: Binding<String> {
        Binding(
            get: {
                switch action {
                case .setField(let name, _, _, _, _), .setComputed(let name, _, _): name
                default: ""
                }
            },
            set: { name in
                switch action {
                case .setField(_, let pattern, let aggregate, let op, let operand):
                    action = .setField(name: name, pattern: pattern, aggregate: aggregate, op: op, operand: operand)
                case .setComputed(_, let formula, let aggregate): action = .setComputed(name: name, formula: formula, aggregate: aggregate)
                default: break
                }
            })
    }

    @State private var operandText = ""

    private var aggregate: Binding<FieldAggregate> {
        Binding(
            get: {
                switch action {
                case .setField(_, _, let aggregate, _, _), .setComputed(_, _, let aggregate): aggregate
                default: .sum
                }
            },
            set: { aggregate in
                switch action {
                case .setField(let name, let pattern, _, let op, let operand):
                    action = .setField(name: name, pattern: pattern, aggregate: aggregate, op: op, operand: operand)
                case .setComputed(let name, let formula, _): action = .setComputed(name: name, formula: formula, aggregate: aggregate)
                default: break
                }
            })
    }

    private var op: Binding<FieldOperator?> {
        Binding(
            get: { if case .setField(_, _, _, let op, _) = action { op } else { nil } },
            set: { op in
                if case .setField(let name, let pattern, let aggregate, _, let operand) = action {
                    action = .setField(name: name, pattern: pattern, aggregate: aggregate, op: op, operand: op == nil ? nil : operand)
                }
            })
    }

    private func setOperand(_ text: String) {
        if case .setField(let name, let pattern, let aggregate, let op, _) = action {
            action = .setField(
                name: name, pattern: pattern, aggregate: aggregate, op: op,
                operand: Double(text.replacingOccurrences(of: ",", with: ".")))
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Action", selection: kind) {
                Text("Add tag").tag(Kind.tag)
                Text("Move to collection").tag(Kind.move)
                Text("Set date from text").tag(Kind.date)
                Text("Set field from text").tag(Kind.field)
                Text("Calculate field").tag(Kind.computed)
                Text("Set title").tag(Kind.title)
            }
            if kind.wrappedValue == .field || kind.wrappedValue == .computed {
                TextField("Field name", text: fieldName)
            }
            HStack {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let suggestions = kind.wrappedValue == .move ? collections : kind.wrappedValue == .tag ? tags : []
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
            if case .setDate(let pattern) = action {
                Text("Use {Datum} for the date and {Uhrzeit} for the time, e.g. Ihr Einkauf am {Datum} um {Uhrzeit} Uhr.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !pattern.isEmpty, !DateExtractor.isValid(pattern: pattern) {
                    Text("The pattern needs {Datum} exactly once and {Uhrzeit} at most once.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if case .setField(_, let pattern, _, _, _) = action {
                Text("Use {Zahl}, {Datum} or {Text} once, e.g. Gesamtbetrag (EUR) {Zahl}. A number format makes 1.234 clear: {Zahl|#.###,##} is German, {Zahl|#,###.##} English.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !pattern.isEmpty, !FieldExtractor.isValid(pattern: pattern) {
                    Text("The pattern needs exactly one of {Zahl}, {Datum} or {Text}.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if case .setField = action {
                Picker("Calculation", selection: op) {
                    Text("None").tag(FieldOperator?.none)
                    ForEach(FieldOperator.allCases, id: \.self) { Text(verbatim: $0.symbol).tag(FieldOperator?.some($0)) }
                }
                if op.wrappedValue != nil {
                    // Own text state so a half-typed number such as "1." is not reformatted while typing.
                    TextField("Number", text: $operandText)
                        .keyboardType(.numbersAndPunctuation)
                        .onChange(of: operandText) { _, text in setOperand(text) }
                        .onAppear {
                            if case .setField(_, _, _, _, .some(let value)) = action { operandText = "\(value)" }
                        }
                    if case .setField(_, let pattern, _, .some, let value) = action, !FieldExtractor.isNumber(pattern: pattern) || value == nil
                        || (op.wrappedValue == .divide && value == 0)
                    {
                        Text("Calculations need a {Zahl} pattern and a number, and cannot divide by 0.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if case .setComputed(_, let formula, _) = action {
                Text("Use field names in braces with + − × ÷ and parentheses, e.g. {Netto} + {MwSt}. Fields without a value leave this field unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !formula.isEmpty, (FormulaEvaluator.references(in: formula) ?? []).isEmpty {
                    Text("The formula needs at least one field name in braces and must be valid.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if kind.wrappedValue == .field || kind.wrappedValue == .computed {
                Picker("Lists show", selection: aggregate) {
                    ForEach(FieldAggregate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            if case .setTitle(let template) = action {
                Text("Use field names in braces, e.g. Tesla {Rechnungsdatum}. Fields are read before the title is set.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !template.isEmpty, TitleTemplate.placeholders(in: template).isEmpty {
                    Text("The template needs at least one field name in braces.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var placeholder: LocalizedStringKey {
        switch kind.wrappedValue {
        case .tag: "Tag"
        case .move: "Collection"
        case .date, .field: "Pattern"
        case .computed: "Formula"
        case .title: "Template"
        }
    }
}

extension FieldAggregate {
    var title: LocalizedStringKey {
        switch self {
        case .sum: "Sum"
        case .average: "Average"
        case .median: "Median"
        case .min: "Minimum"
        case .max: "Maximum"
        case .stdDev: "Standard deviation"
        case .count: "Count"
        }
    }
}

extension FieldOperator {
    var symbol: String {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        }
    }
}
