import SwiftUI
import AppKit

struct LibraryGridView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("thumbSize") private var thumbSize: Double = 200

    private var library: Library { state.library }
    private var visible: [Photo] { state.visiblePhotos }
    /// The search field writes its text back on every update; publishing only real changes keeps that
    /// from re-rendering the grid in a loop.
    /// Search and filters live above the grid, not in the toolbar: pop-up pickers inside the toolbar made
    /// SwiftUI re-lay out the window in a loop once the grid was scrolled off the top (macOS 26).
    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
                TextField("Search", text: searchBinding, prompt: Text("Search captions, tags, files"))
                    .textFieldStyle(.plain).frame(width: 170)
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .help("Search file names, tags, the model's captions and categories, and day titles")
            Toggle(isOn: guarded(\.showFlaggedOnly)) { Label("Flagged", systemImage: state.showFlaggedOnly ? "flag.fill" : "flag") }
                .toggleStyle(.button)
                .help(state.showFlaggedOnly ? "Showing flagged photos only (⇧⌘F)" : "Show flagged photos only (⇧⌘F)")
            Picker(selection: guarded(\.minRating)) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { n in Text(String(repeating: "★", count: n) + (n < 5 ? " and up" : "")).tag(n) }
            } label: { Label("Rating", systemImage: state.minRating > 0 ? "star.fill" : "star") }
            .frame(width: 190)
            .help("Show photos rated at least this many stars")
            if !library.allTags.isEmpty || state.tagFilter != nil {
                Picker(selection: guarded(\.tagFilter)) {
                    Text("Any Tag").tag(String?.none)
                    ForEach(library.allTags, id: \.tag) { t in Text("\(t.tag) (\(t.count))").tag(Optional(t.tag)) }
                } label: { Label("Tag", systemImage: state.tagFilter == nil ? "tag" : "tag.fill") }
                .frame(width: 210)
                .help("Show photos with this tag only")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func cellMenu(_ photo: Photo) -> some View {
        Button("Open") { state.open(photo.id) }
        Button(library.photos.filter { contextTargets(photo).contains($0.id) }.allSatisfy(\.flagged) ? "Unflag" : "Flag") { state.toggleFlag(contextTargets(photo)) }
        Menu("Rating") {
            ForEach(0...5, id: \.self) { n in Button(n == 0 ? "No Rating" : String(repeating: "★", count: n)) { state.setRating(n, contextTargets(photo)) } }
        }
        Menu("Tags") {
            ForEach(library.allTags, id: \.tag) { t in
                Toggle(t.tag, isOn: Binding(get: { state.targetsHaveTag(t.tag, contextTargets(photo)) },
                                            set: { on in on ? state.addTags(t.tag, to: contextTargets(photo)) : state.removeTag(t.tag, from: contextTargets(photo)) }))
            }
            if !library.allTags.isEmpty { Divider() }
            Button("New Tag…") { state.promptNewTag(contextTargets(photo)) }
        }
        Menu("Apply Preset") {
            ForEach(library.presets) { p in Button(p.name) { state.applyPreset(p, to: contextTargets(photo)) } }
            if !library.presets.isEmpty { Divider() }
            ForEach(Preset.builtIn) { p in Button(p.name) { state.applyPreset(p, to: contextTargets(photo)) } }
        }
        if state.blankEnabled {
            Button("Publish to Blank…") { state.publishToBlank(contextTargets(photo)) }
            if let post = photo.blankPost { Button("Open on Blank") { NSWorkspace.shared.open(post.url) } }
        }
        Button("Export JPEG") { state.selection = [photo.id]; state.exportSelected() }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.paths.original(photo)]) }
        if let jpeg = library.exportedJPEG(photo) {
            Button("Show Exported JPEG in Finder") { NSWorkspace.shared.activateFileViewerSelecting([jpeg]) }
        }
        Divider()
        Button("Remove from Library…") { state.selection = [photo.id]; state.removeSelected() }
    }

    private func guarded<V: Equatable>(_ key: ReferenceWritableKeyPath<AppState, V>) -> Binding<V> {
        Binding(get: { state[keyPath: key] }, set: { new in if state[keyPath: key] != new { state[keyPath: key] = new } })
    }
    private var searchBinding: Binding<String> {
        Binding(get: { state.searchText }, set: { new in if state.searchText != new { state.searchText = new } })
    }
    /// A context-menu command acts on the selection when the clicked photo is part of it, else on that photo.
    private func contextTargets(_ photo: Photo) -> Set<Photo.ID> { state.selection.contains(photo.id) ? state.selection : [photo.id] }

    var body: some View {
        Debug.tick("grid.body")
        return VStack(spacing: 0) {
            if !library.photos.isEmpty { filterBar }
            if library.photos.isEmpty {
                EmptyLibraryView()
            } else if state.isFiltering && visible.isEmpty {
                NoMatchView()
            } else {
                ScrollView {
                    // one lazy grid with section headers, not lazy grids nested in a lazy stack: the nested
                    // estimates kept SwiftUI re-laying out the window endlessly on macOS 26
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.5), spacing: 10)], spacing: 10) {
                        ForEach(library.dayGroups(visible)) { group in
                            Section {
                                ForEach(group.photos) { photo in
                                    ThumbnailCell(photo: photo, selected: state.selection.contains(photo.id))
                                        .onTapGesture(count: 2) { state.open(photo.id) }
                                        .onTapGesture { select(photo) }
                                        .contextMenu { cellMenu(photo) }
                                }
                            } header: {
                                DayHeader(title: group.title, count: group.photos.count, session: group.session)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onTapGesture { state.selection = [] }
            }
            StatusBar()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.importViaPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import X3F files or folders (⌘I)")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings (⌘,)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Slider(value: $thumbSize, in: 120...360).frame(width: 90).help("Thumbnail size")
                if state.blankEnabled {
                    Button { state.publishToBlank() } label: { Label("Publish to Blank", systemImage: "paperplane") }
                        .help("Publish the selected photos as a Blank post (⇧⌘P)")
                        .disabled(state.selection.isEmpty)
                }
                Button { state.exportSelected() } label: { Label("Export JPEG", systemImage: "photo.badge.arrow.down") }
                    .help("Export full-size JPEG to the library's Exports folder (⌘E)")
                    .disabled(state.selection.isEmpty || state.exportProgress != nil)
                ShareButton(enabled: !state.selection.isEmpty && state.exportProgress == nil) { view in state.share(anchor: view) }
            }
        }
        .navigationTitle(library.photos.isEmpty ? "X3F Studio" : state.isFiltering ? "\(visible.count) of \(library.photos.count) photos" : "\(library.photos.count) photos")
        .onKeyPress(.return) { if state.selection.count == 1, let id = state.selection.first { state.open(id); return .handled }; return .ignored }
        .onKeyPress(.space) { if state.selection.count == 1, let id = state.selection.first { state.open(id); return .handled }; return .ignored }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isEmpty, !state.selection.isEmpty else { return .ignored }
            switch press.characters {
            case ".": state.toggleFlag(state.selection); return .handled
            case "u": state.unflag(state.selection); return .handled
            default: return .ignored
            }
        }
    }

    private func select(_ photo: Photo) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if state.selection.contains(photo.id) { state.selection.remove(photo.id) } else { state.selection.insert(photo.id) }
        } else if flags.contains(.shift), let anchor = state.selection.first,
                  let a = library.photos.firstIndex(where: { $0.id == anchor }), let b = library.photos.firstIndex(where: { $0.id == photo.id }) {
            state.selection = Set(library.photos[min(a, b)...max(a, b)].map(\.id))
        } else {
            state.selection = [photo.id]
        }
    }
}

/// A day's heading, set large like a display headline, scrolling with its photos.
struct DayHeader: View {
    let title: String
    let count: Int
    var session: SessionInfo? = nil
    var body: some View {
        Debug.tick("header.body")
        // A fixed-height plain row (not a Section header, no tooltips, single-line texts): a header whose
        // height depended on its text made the lazy stack re-lay out endlessly on macOS 26.
        // the day's title and its categories only; the model's longer summary stays in the catalog
        let rows = session == nil ? 1 : 2
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 32, weight: .semibold)).tracking(-0.5).lineLimit(1)
                Text("\(count)").font(.title3).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            if let s = session {
                HStack(spacing: 8) {
                    Text(s.title).font(.title3).lineLimit(1)
                    if !s.categories.isEmpty { Text(s.categories.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(height: rows == 1 ? 62 : 88, alignment: .topLeading)
        .clipped()
    }
}

struct ThumbnailCell: View {
    @EnvironmentObject var state: AppState
    let photo: Photo
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        Debug.tick("cell.body")
        return VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06))
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(2)
                } else {
                    // a static placeholder: animated spinners in many cells kept invalidating the layout and
                    // starved the thumbnail loads, freezing the grid (macOS 26)
                    Image(systemName: "photo").font(.system(size: 22, weight: .light)).foregroundStyle(.quaternary)
                }
                VStack {
                    HStack {
                        if photo.flagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2).padding(8) }
                        Spacer()
                        EditBadges(photo: photo, size: 11).padding(8)
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        // rated photos show their stars (rate with the 1–5 keys or in the editor; hover-to-rate here
                        // made SwiftUI re-render the grid in a loop)
                        if photo.rating > 0 {
                            StarRating(rating: photo.rating, size: 10, showEmpty: false, showHelp: false) { state.setRating($0, [photo.id]) }
                                .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2).padding(8)
                        }
                        if !photo.engine.isSupported { Text("Camera JPEG").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial, in: Capsule()).padding(6) }
                        Spacer()
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.primary : .clear, lineWidth: 3).padding(-2))
            Text(photo.fileName).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: "\(photo.id)-\(state.renders.derivativesVersion)") {
            let url = state.library.paths.thumb(photo)
            let img = await ThumbnailCache.shared.image(for: url)
            if !Task.isCancelled { image = img }
        }
    }
}

/// Small in-memory cache for grid thumbnails keyed by file URL + modification date.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []

    func image(for url: URL) -> CGImage? {
        Debug.tick("thumb.lookup")
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(url.path)@\(mtime)"
        if let c = cache[key] { return c }
        Debug.tick("thumb.decode")
        guard let img = RawImage.cgImage(file: url, maxPixel: 640) else { return nil }
        cache[key] = img; order.append(key)
        if order.count > 600 { let old = order.removeFirst(); cache.removeValue(forKey: old) }
        return img
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "camera.aperture").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("Your Sigma photos, developed by SIGMA's own engine").font(.title2)
            Text("Import X3F files or a whole folder. They're copied into\n\(state.library.paths.root.path)\norganised by capture date.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            Button("Import Photos…") { state.importViaPanel() }.keyboardShortcut("i").buttonStyle(.borderedProminent).controlSize(.large)
            Text("or drop them anywhere in this window").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What was done to a photo, as Lightroom shows it: sliders for adjustments, a crop mark for a crop or turn.
struct EditBadges: View {
    @EnvironmentObject var state: AppState
    let photo: Photo
    var size: CGFloat = 11
    var body: some View {
        HStack(spacing: size * 0.4) {
            // no .help() tooltips: inside the lazy grid they send SwiftUI's layout into a loop
            if photo.hasAdjustments { Image(systemName: "slider.horizontal.3") }
            if photo.hasCustomCrop { Image(systemName: "crop") }
            if !photo.tags.isEmpty { Image(systemName: "tag.fill") }
            if photo.blankPost != nil { Image(systemName: "paperplane.fill") }
            if state.tagging.reviewEnabled, photo.aiAdvice?.needsWork == true { Image(systemName: "wand.and.stars").foregroundStyle(.orange) }
            if photo.exportedAt != nil || state.library.exportedJPEG(photo) != nil {
                // a JPEG version exists: in the Exports folder, or exported / shared elsewhere (dimmed if edited since)
                let current = photo.exportedSettings == nil || photo.isExportCurrent
                Image(systemName: "photo.badge.arrow.down").opacity(current ? 1 : 0.55)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 2)
    }

}

/// Sun / moon toolbar button: switches between the light and dark appearance (View ▸ Appearance has System too).
struct AppearanceButton: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Button { state.toggleDarkAppearance() } label: {
            Label(state.isDarkAppearance ? "Light Appearance" : "Dark Appearance", systemImage: state.isDarkAppearance ? "sun.max" : "moon")
        }
        .help(state.isDarkAppearance ? "Switch to the light appearance" : "Switch to the dark appearance")
    }
}

/// Five stars to show or set a rating: click a star to set it, click the current one to clear it.
struct StarRating: View {
    let rating: Int
    var size: CGFloat = 12
    var showEmpty = true
    var emptyOpacity: Double = 0.45
    var showHelp = true
    var onSet: ((Int) -> Void)? = nil
    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(1...5, id: \.self) { n in
                if n <= rating || showEmpty {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .opacity(n <= rating ? 1 : emptyOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture { onSet?(n == rating ? 0 : n) }
                }
            }
        }
        .help(showHelp ? (rating == 0 ? "Rate: click a star, or press 1–5 (0 clears)" : "\(rating) star\(rating == 1 ? "" : "s") · click the same star or press 0 to clear") : "")
    }
}

struct NoMatchView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: state.showFlaggedOnly ? "flag" : "star").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("No photos match").font(.title3)
            Text(!state.searchText.isEmpty ? "Nothing matches “\(state.searchText)”."
                 : state.showFlaggedOnly && state.minRating > 0 ? "Nothing is both flagged and rated \(state.minRating)+ stars."
                 : state.showFlaggedOnly ? "Select photos and press P to flag them." : "Select photos and press 1–5 to rate them.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Show All Photos") { state.clearFilters() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let _ = Debug.tick("statusbar.body")
        let lib = state.library, r = state.renders
        let importing = lib.importProgress
        let rendering = r.isBackgroundBusy
        let tagging = state.tagging
        if importing != nil || rendering || tagging.isRunning || lib.lastImportSummary != nil || r.engineError != nil {
            HStack(spacing: 10) {
                if let p = importing {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 140)
                    Text("Importing \(p.done + 1) of \(p.total) · \(p.currentName)").font(.caption)
                } else if rendering {
                    ProgressView(value: Double(r.backgroundDone), total: Double(max(1, r.backgroundTotal))).frame(width: 140)
                    Text("Developing previews with the SIGMA engine · \(r.backgroundDone) of \(r.backgroundTotal)").font(.caption)
                } else if tagging.isRunning {
                    ProgressView(value: Double(tagging.done), total: Double(max(1, tagging.total))).frame(width: 140)
                    Text("Categorising with \(tagging.modelName) · \(min(tagging.done + 1, tagging.total)) of \(tagging.total)" + (tagging.current.map { " · \($0)" } ?? "")).font(.caption).lineLimit(1)
                } else if let s = lib.lastImportSummary {
                    Text(s).font(.caption)
                }
                Spacer()
                if let e = r.engineError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1).help(e)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
