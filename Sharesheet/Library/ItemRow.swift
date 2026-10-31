import SharesheetCore
import SharesheetUI
import SwiftUI
import UIKit

/// One library item: favicon or type icon, title, source, tags, saved date and a pending-capture badge.
struct ItemRow: View {
    let item: IndexedItem
    let favicon: Data?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    source
                    Text(verbatim: "·")
                    Text(item.created, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !item.tags.isEmpty { tagChips }
            }
            Spacer(minLength: 0)
            if item.capture == .pending {
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Capture pending"))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        if let favicon, let image = UIImage(data: favicon) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            ItemTypeIcon(item.type)
                .font(.title3)
                .foregroundStyle(.tint)
        }
    }

    /// The domain for web items; the type for files and text.
    @ViewBuilder private var source: some View {
        if item.file == nil, item.type != .text, let domain = item.domain {
            Text(verbatim: domain)
        } else {
            Text(item.type.label)
        }
    }

    /// One line of chips; tags that do not fit are cut off.
    private var tagChips: some View {
        HStack(spacing: 4) {
            ForEach(item.tags, id: \.self) { tag in
                Text(verbatim: tag)
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
