import SwiftUI
import UniformTypeIdentifiers

/// Adds an item from inside the app: first a link, text or files, then the same form as the share sheet.
struct AddItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var files: [URL] = []
    @State private var picksFiles = false
    @State private var form: ShareFormModel?

    var body: some View {
        if let form {
            ShareFormView(model: form)
        } else {
            input
        }
    }

    private var input: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link or text", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first }
                    }
                }
                Section {
                    ForEach(files, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: "doc")
                    }
                    .onDelete { files.remove(atOffsets: $0) }
                    Button {
                        picksFiles = true
                    } label: {
                        Label("Add files", systemImage: "paperclip")
                    }
                }
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { showForm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isEmpty)
                }
            }
            .fileImporter(isPresented: $picksFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let picked) = result { files += picked }
            }
        }
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
    }

    private func showForm() {
        form = ShareFormModel(text: text, files: files) { saved in
            dismiss()
            if saved { Task { await model.refresh() } }
        }
    }
}
