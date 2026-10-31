import SwiftUI

/// Tag chips plus an input. Comma or return commits the typed token; backspace on an empty input
/// removes the last tag; suggestions matching the typed prefix can be tapped to add.
public struct TagField: View {
    /// Keeps the field non-empty so a backspace on "empty" input is observable as a change.
    private static let sentinel = "\u{200B}"
    private static let maxSuggestions = 8

    @Binding private var tags: [String]
    private let suggestions: [String]
    @State private var input = TagField.sentinel
    @FocusState private var focused: Bool

    public init(tags: Binding<[String]>, suggestions: [String]) {
        self._tags = tags
        self.suggestions = suggestions
    }

    private var typed: String { input.replacingOccurrences(of: Self.sentinel, with: "") }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Label(tag, systemImage: "xmark")
                                    .labelStyle(TrailingIconLabelStyle())
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.tint.opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            TextField("Tags", text: $input)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif
                .onSubmit {
                    commit(typed)
                    focused = true
                }
                .onChange(of: input) { _, newValue in handleChange(newValue) }
                .overlay(alignment: .leading) {
                    if typed.isEmpty {
                        Text("Add tags").foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
            let matches = Self.matches(for: typed, in: suggestions, excluding: tags)
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.self) { tag in
                            Button(tag) { commit(tag) }
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
        }
    }

    private func handleChange(_ newValue: String) {
        if newValue.isEmpty {
            // The sentinel was deleted: backspace on an empty input.
            if !tags.isEmpty { tags.removeLast() }
            input = Self.sentinel
            return
        }
        let text = newValue.replacingOccurrences(of: Self.sentinel, with: "")
        guard text.contains(",") else {
            if !newValue.hasPrefix(Self.sentinel) { input = Self.sentinel + text }
            return
        }
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rest = parts.removeLast()
        for part in parts { tags = Self.adding(part, to: tags) }
        input = Self.sentinel + rest
    }

    private func commit(_ token: String) {
        tags = Self.adding(token, to: tags)
        input = Self.sentinel
    }

    /// `tags` plus the trimmed token, unless it is empty or already present (case-insensitively).
    static func adding(_ token: String, to tags: [String]) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return tags }
        return tags + [trimmed]
    }

    /// Up to eight suggestions starting with `prefix` (case-insensitively), not already chosen.
    static func matches(for prefix: String, in suggestions: [String], excluding chosen: [String]) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let chosenSet = Set(chosen.map { $0.lowercased() })
        return Array(suggestions.lazy
            .filter { $0.lowercased().hasPrefix(needle) && !chosenSet.contains($0.lowercased()) }
            .prefix(maxSuggestions))
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
