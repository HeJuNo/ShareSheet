import Foundation
import SharesheetCore
import SwiftUI

/// Broken links with their last status; swipe to recheck or delete, tap to open the item.
struct BrokenLinksView: View {
    @Environment(AppModel.self) private var model
    @State private var isChecking = false
    @State private var deleteFailure = false

    var body: some View {
        let links = model.brokenLinks()
        List {
            ForEach(links) { link in
                NavigationLink(value: link.item.id) {
                    HStack(alignment: .top, spacing: 8) {
                        ItemRow(item: link.item, favicon: model.favicon(for: link.item))
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(link.check.httpStatus.map { "HTTP \($0)" } ?? "Unreachable")
                            Text(link.check.checked, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        recheck(link.item.url)
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(link)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Broken links")
        .overlay {
            if links.isEmpty {
                ContentUnavailableView("No broken links", systemImage: "link")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    checkNow()
                } label: {
                    if isChecking {
                        ProgressView()
                    } else {
                        Text("Check now")
                    }
                }
                .disabled(isChecking)
            }
        }
        .alert("Couldn’t delete the item", isPresented: $deleteFailure) {
            Button("OK") {}
        }
    }

    private func checkNow() {
        Task {
            isChecking = true
            await model.checkLinksNow()
            isChecking = false
        }
    }

    private func recheck(_ url: URL?) {
        guard let url else { return }
        Task { await model.recheckLink(url) }
    }

    private func delete(_ link: BrokenLink) {
        Task {
            do { try await model.delete(link.item.id) } catch { deleteFailure = true }
        }
    }
}
