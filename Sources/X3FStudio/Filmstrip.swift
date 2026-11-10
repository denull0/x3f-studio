import SwiftUI

/// The strip of photos under the editor (Lightroom-style): grouped by day with a gap between days,
/// the current photo highlighted, click to open another, arrows at both ends, and a header that
/// folds it away. It shows what the library shows (flagged only, when that filter is on), in the
/// grid's order — newest day first, chronological within a day — which is also the arrows' order.
struct Filmstrip: View {
    @EnvironmentObject var state: AppState
    private let thumbHeight: CGFloat = 60

    private var groups: [Library.DayGroup] { state.library.dayGroups(state.visiblePhotos) }
    private var photos: [Photo] { state.orderedPhotos }
    private var index: Int? { state.editingID.flatMap { id in photos.firstIndex { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if state.filmstripShown {
                strip.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.filmstripShown ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(position).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if state.showFlaggedOnly {
                Label("Flagged only", systemImage: "flag.fill").font(.caption).foregroundStyle(.secondary)
            }
            if state.minRating > 0 {
                Text(String(repeating: "★", count: state.minRating) + (state.minRating < 5 ? " and up" : "")).font(.caption).foregroundStyle(.secondary)
            }
            if let t = state.tagFilter {
                Label(t, systemImage: "tag.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleFilmstrip() }
        .help(state.filmstripShown ? "Hide the photo strip" : "Show the photo strip")
    }

    private var position: String {
        guard let i = index else { return "\(photos.count) photos" }
        return "\(i + 1) of \(photos.count)"
    }

    private var strip: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", delta: -1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // A plain stack of fixed-size thumbs, not a lazy one: with whole days as lazy items of
                    // changing width, scrolling to a photo deep in a large day sent the lazy stack's
                    // estimate/place cycle into an endless loop on macOS 26 (sampled 10 Nov 2026).
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Filmstrip.dayLabel(group.id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 1)
                                HStack(spacing: 6) {
                                    ForEach(group.photos) { photo in
                                        FilmstripThumb(photo: photo, current: photo.id == state.editingID, height: thumbHeight)
                                            .id(photo.id)
                                            .onTapGesture { state.goTo(photo.id) }
                                    }
                                }
                            }
                            .padding(.trailing, 26)   // the gap between days
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .onChange(of: state.editingID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear {
                    if let id = state.editingID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            arrow("chevron.right", delta: 1)
        }
        .frame(height: thumbHeight + 30)
    }

    /// "Sat, 7 Nov 2026" — short enough for the strip.
    static func dayLabel(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private func arrow(_ name: String, delta: Int) -> some View {
        let enabled = state.canStep(delta)
        return Button { state.step(delta) } label: {
            Image(systemName: name).font(.title3.weight(.semibold))
                .frame(width: 28, height: thumbHeight + 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
        .disabled(!enabled)
        .help(delta < 0 ? "Previous photo (←)" : "Next photo (→)")
    }
}

struct FilmstripThumb: View {
    @EnvironmentObject var state: AppState
    let photo: Photo
    let current: Bool
    let height: CGFloat
    @State private var image: CGImage?

    /// The thumb's width follows the photo's own proportions, so the strip's layout is settled before
    /// any thumbnail has loaded and never moves afterwards.
    private var width: CGFloat { (height * max(0.4, min(2.5, photo.aspectRatio))).rounded() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFill()
                    .frame(width: width, height: height).clipped()
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.08)).frame(width: width, height: height)
            }
            if photo.flagged {
                Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 1.5).padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) { EditBadges(photo: photo, size: 8).padding(4) }
        .overlay(alignment: .bottomLeading) {
            if photo.rating > 0 {
                StarRating(rating: photo.rating, size: 7, showEmpty: false).foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 1.5).padding(4).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(current ? Color.primary : .clear, lineWidth: 2).padding(-1))
        .opacity(current ? 1 : 0.85)
        .task(id: "\(photo.id)-\(state.renders.derivativesVersion)") {
            let img = await ThumbnailCache.shared.image(for: state.library.paths.thumb(photo))
            if !Task.isCancelled { image = img }
        }
    }
}
