import SwiftUI

/// The tag editor in the adjustments panel: the photo's tags as chips (× removes), a field to add
/// more (commas separate several), and a menu of the tags used elsewhere in the library.
struct TagsEditor: View {
    @EnvironmentObject var state: AppState
    let photoID: Photo.ID
    @State private var text = ""
    @FocusState private var focused: Bool

    private var tags: [String] { state.library.photo(id: photoID)?.tags ?? [] }
    private var aiTags: [String] { state.library.photo(id: photoID)?.aiTags ?? [] }
    private var others: [String] { state.library.allTags.map(\.tag).filter { t in !tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TAGS").font(.system(size: 11, weight: .light)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if others.isEmpty { Text("No other tags in the library yet") }
                    ForEach(others, id: \.self) { t in Button(t) { state.addTags(t, to: [photoID]) } }
                } label: {
                    Image(systemName: "tag")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .help("Add a tag already used in the library")
            }
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag) { state.removeTag(tag, from: [photoID]) }
                    }
                }
            }
            if !aiTags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(aiTags, id: \.self) { tag in
                        TagChip(tag: tag, ai: true) { state.library.removeAITag(tag, from: photoID) }
                    }
                }
                .help("Suggested by the local model; × removes one")
            }
            TextField("Add tag…", text: $text)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .focused($focused)
                .onSubmit { state.addTags(text, to: [photoID]); text = "" }
                .onChange(of: focused) { _, f in state.textEditing = f }
                .help("Type a tag and press Return; separate several with commas")
        }
    }
}

struct TagChip: View {
    let tag: String
    var ai = false
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 3) {
            if ai { Image(systemName: "sparkles").font(.system(size: 8)).foregroundStyle(.secondary) }
            Text(tag).font(.system(.caption, design: .monospaced)).lineLimit(1).foregroundStyle(ai ? .secondary : .primary)
            if let onRemove {
                Button { onRemove() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this tag")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.secondary.opacity(ai ? 0.09 : 0.18), in: Capsule())
    }
}

/// Lays its children out in rows, wrapping like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
