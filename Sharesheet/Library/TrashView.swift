import SharesheetCore
import SwiftUI

/// Deleted items: restore them, delete them for good, or empty the Trash.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TrashSettings.autoEmptyKey) private var autoEmpty = TrashSettings.defaultAutoEmpty
    @AppStorage(TrashSettings.daysKey) private var days = TrashSettings.defaultDays
    @State private var pendingPurge: TrashedItem?
    @State private var confirmsEmpty = false
    @State private var failed = false

    var body: some View {
        List {
            ForEach(model.trashed) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.title)
                    subtitle(entry)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        restore(entry)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingPurge = entry
                    } label: {
                        Label("Delete Now", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: Text("Restore")) { restore(entry) }
            }
        }
        .overlay {
            if model.trashed.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash")
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Empty Trash", role: .destructive) { confirmsEmpty = true }
                    .disabled(model.trashed.isEmpty)
            }
        }
        .task {
            await model.purgeExpired()
        }
        .confirmationDialog(
            "Delete this item for good?", isPresented: $pendingPurge.isPresent(), titleVisibility: .visible,
            presenting: pendingPurge
        ) { entry in
            Button("Delete Now", role: .destructive) { run { try await model.purge(entry) } }
        } message: { entry in
            Text("“\(entry.title)” can’t be restored afterwards.")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmsEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { run { try await model.emptyTrash() } }
        } message: {
            Text("All items in the Trash are deleted for good.")
        }
        .alert("Something went wrong", isPresented: $failed) { Button("OK") {} }
    }

    private func subtitle(_ entry: TrashedItem) -> Text {
        let deleted = entry.deletedAt.formatted(.relative(presentation: .named))
        guard autoEmpty else { return Text("Deleted \(deleted)") }
        let left = max(0, Calendar.current.dateComponents([.day], from: .now, to: entry.deletedAt.addingTimeInterval(Double(days) * 86_400)).day ?? 0)
        return Text("Deleted \(deleted) · removed in \(left) days")
    }

    private func restore(_ entry: TrashedItem) { run { try await model.restore(entry) } }

    private func run(_ work: @escaping () async throws -> some Any) {
        Task {
            do { _ = try await work() } catch { failed = true }
        }
    }
}

/// Shown for a few seconds after a delete: takes the item back out of the Trash.
struct UndoDeleteBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.lastDeleted {
            HStack {
                Text("Deleted")
                Spacer()
                Button("Undo") {
                    Task { try? await model.restore(entry) }
                }
                .fontWeight(.semibold)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: entry.id) {
                try? await Task.sleep(for: .seconds(5))
                if model.lastDeleted == entry { withAnimation { model.lastDeleted = nil } }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
