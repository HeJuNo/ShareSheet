import SharesheetCore
import SwiftUI

/// Edits the value of one field by hand; rules leave it alone afterwards.
struct FieldEditSheet: View {
    let name: String
    let onSave: (FieldValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var number: Double?
    @State private var date: Date
    @State private var text: String
    private let original: FieldValue

    init(name: String, value: FieldValue, onSave: @escaping (FieldValue) -> Void) {
        self.name = name
        self.onSave = onSave
        original = value
        var number: Double?
        var date = Date.now
        var text = ""
        switch value {
        case .number(let value): number = value
        case .date(let value): date = value
        case .text(let value): text = value
        }
        _number = State(initialValue: number)
        _date = State(initialValue: date)
        _text = State(initialValue: text)
    }

    private var edited: FieldValue? {
        switch original {
        case .number: number.map(FieldValue.number)
        case .date: .date(date)
        case .text:
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch original {
                    case .number:
                        TextField("Value", value: $number, format: .number.precision(.fractionLength(0...6)))
                            .keyboardType(.numbersAndPunctuation)
                    case .date:
                        DatePicker("Value", selection: $date, displayedComponents: .date)
                    case .text:
                        TextField("Value", text: $text, axis: .vertical)
                    }
                } footer: {
                    Text("Rules no longer change this field after you edit it.")
                }
            }
            .navigationTitle(Text(verbatim: name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let edited { onSave(edited) }
                        dismiss()
                    }
                    .disabled(edited == nil || edited == original)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
