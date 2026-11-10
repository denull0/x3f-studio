import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    let library: Library
    let renders: RenderService
    /// The Blank (blank.is) account photos are published to.
    let blank = BlankAccount()
    /// Categorises photos and days with a local model (Ollama).
    let tagging = TaggingService()

    @Published var selection: Set<Photo.ID> = []
    @Published var editingID: Photo.ID?
    @Published var exportProgress: ExportProgress?
    @Published var alert: AlertInfo?
    @Published var pendingRemoval: Set<Photo.ID>?
    @Published var zoomCommand: ZoomCommand?
    private var zoomSerial = 0
    private var cancellables = Set<AnyCancellable>()

    func zoom(_ action: ZoomAction) { zoomSerial += 1; zoomCommand = ZoomCommand(action: action, serial: zoomSerial) }

    /// The editor's crop tool (Photos-style): shows the whole frame with a draggable rectangle.
    @Published var cropMode = false
    func toggleCrop() { guard editingID != nil else { return }; cropMode.toggle() }

    /// The photo strip under the editor.
    @Published var filmstripShown = UserDefaults.standard.object(forKey: "filmstrip.shown") as? Bool ?? true {
        didSet { defaults.set(filmstripShown, forKey: "filmstrip.shown") }
    }
    func toggleFilmstrip() { withAnimation(.easeInOut(duration: 0.22)) { filmstripShown.toggle() } }

    /// The library shows (and the editor steps through) flagged photos only.
    @Published var showFlaggedOnly = UserDefaults.standard.bool(forKey: "filter.flaggedOnly") {
        didSet { defaults.set(showFlaggedOnly, forKey: "filter.flaggedOnly") }
    }
    /// Show photos rated at least this many stars (0 = any).
    @Published var minRating = min(5, max(0, UserDefaults.standard.integer(forKey: "filter.minRating"))) {
        didSet { defaults.set(minRating, forKey: "filter.minRating") }
    }
    /// Show photos carrying this tag only.
    @Published var tagFilter: String? = UserDefaults.standard.string(forKey: "filter.tag") {
        didSet { defaults.set(tagFilter, forKey: "filter.tag") }
    }
    /// The library's search field: file names, tags, the model's captions and categories, day titles.
    @Published var searchText = ""
    var isFiltering: Bool { showFlaggedOnly || minRating > 0 || tagFilter != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    func clearFilters() { showFlaggedOnly = false; minRating = 0; tagFilter = nil; searchText = "" }
    var visiblePhotos: [Photo] {
        guard isFiltering else { return library.photos }
        let words = searchText.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var dayText: [String: String] = [:]
        if !words.isEmpty { for (k, s) in library.sessions { dayText[k] = (s.title + " " + s.summary + " " + s.categories.joined(separator: " ")).lowercased() } }
        return library.photos.filter { p in
            guard (!showFlaggedOnly || p.flagged), p.rating >= minRating, tagFilter.map(p.hasTag) ?? true else { return false }
            guard !words.isEmpty else { return true }
            let text = p.searchText + " " + (dayText[Library.dayKey(for: p.captureDate)] ?? "")
            return words.allSatisfy { text.contains($0) }
        }
    }
    /// A text field has the keyboard: the single-key shortcuts (P, C, 0–5) stand down.
    @Published var textEditing = false
    /// The visible photos in the order the library grid and the photo strip show them (newest day
    /// first, chronological within a day); the arrows step through this order.
    var orderedPhotos: [Photo] { library.dayGroups(visiblePhotos).flatMap(\.photos) }

    /// Light or dark, or whatever the system says (the default).
    @Published var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    var isDarkAppearance: Bool {
        appearance == .dark || (appearance == .system && NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    /// The toolbar's sun/moon button: light ↔ dark from whatever is showing now.
    func toggleDarkAppearance() { appearance = isDarkAppearance ? .light : .dark }

    struct ExportProgress { var done: Int; var total: Int; var name: String }
    struct AlertInfo: Identifiable { let id = UUID(); var title: String; var message: String }

    init() {
        LibraryPaths.customExportsDir = UserDefaults.standard.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let lib = Library()
        library = lib
        renders = RenderService(paths: lib.paths)
        renders.library = lib
        tagging.library = lib
        // views observe only AppState; forward the children's changes
        lib.objectWillChange.sink { [weak self] _ in Debug.tick("pub.library"); self?.objectWillChange.send() }.store(in: &cancellables)
        renders.objectWillChange.sink { [weak self] _ in Debug.tick("pub.renders"); self?.objectWillChange.send() }.store(in: &cancellables)
        blank.objectWillChange.sink { [weak self] _ in Debug.tick("pub.blank"); self?.objectWillChange.send() }.store(in: &cancellables)
        tagging.objectWillChange.sink { [weak self] _ in Debug.tick("pub.tagging"); self?.objectWillChange.send() }.store(in: &cancellables)
        objectWillChange.sink { _ in Debug.tick("pub.appstate.total") }.store(in: &cancellables)
        // categorise whatever the local model hasn't seen yet, once the launch has settled
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.tagging.enqueueMissing()
        }
        if !EngineServer.isSigmaPhotoProInstalled {
            renders.engineError = EngineServer.Failure.notInstalled.localizedDescription
        }
        // Thumbnails and previews the engine has not yet made from the photo's current settings (fresh
        // imports, an engine fix) are developed in the background once — not at every launch, whether
        // or not the 16-bit master is still cached.
        // Catalogs from before this was recorded adopt the key when their master is still there.
        for p in lib.photos where p.previewKey == nil && p.engine.isSupported
            && FileManager.default.fileExists(atPath: lib.paths.render(p, settings: p.settings, look: renders.look(for: p, settings: p.settings)).path) {
            lib.setPreviewKey(renders.derivativeKey(for: p), for: p.id)
        }
        // A master for the current settings that is not a TIFF (written while the Quattro engine was
        // clobbering the server's frame, 10 Nov 2026) left the thumbnail and preview behind although
        // the key was recorded: drop it and develop those photos again.
        for p in lib.photos where p.engine.isSupported {
            let master = lib.paths.render(p, settings: p.settings, look: renders.look(for: p, settings: p.settings))
            if FileManager.default.fileExists(atPath: master.path), !RenderService.isValidMaster(master) {
                try? FileManager.default.removeItem(at: master)
                lib.setPreviewKey(nil, for: p.id)
            }
        }
        let stale = lib.photos.filter { $0.engine.isSupported && $0.previewKey != renders.derivativeKey(for: $0) }
        if stale.count <= 400 { renders.enqueue(stale.map(\.id)) }
    }

    // MARK: - Blank

    /// Publishing to Blank is behind a flag for now (Blank's Apple sign-in has no web OAuth secret yet):
    /// `defaults write com.maybethis.x3fstudio blank.enabled -bool YES` shows its buttons, menu item and
    /// Settings section; off hides all of it.
    @Published var blankEnabled: Bool = UserDefaults.standard.bool(forKey: "blank.enabled") {
        didSet { defaults.set(blankEnabled, forKey: "blank.enabled") }
    }
    struct PublishRequest: Identifiable { let id = UUID(); var photos: [Photo] }
    /// The "Publish to Blank" sheet, with the photos it starts from (grid order).
    @Published var publishRequest: PublishRequest?
    /// Longer side of the pictures sent to Blank.
    @Published var blankMaxPixel: Int = [1800, 2400, 3000].contains(UserDefaults.standard.integer(forKey: "blank.maxPixel")) ? UserDefaults.standard.integer(forKey: "blank.maxPixel") : 2400 {
        didSet { defaults.set(blankMaxPixel, forKey: "blank.maxPixel") }
    }
    func publishToBlank(_ ids: Set<Photo.ID>? = nil) {
        guard blankEnabled else { return }
        let wanted = Set(targets(ids).map(\.id))
        let photos = library.dayGroups(library.photos).flatMap(\.photos).filter { wanted.contains($0.id) }
        guard !photos.isEmpty else { return }
        publishRequest = PublishRequest(photos: photos)
    }

    // MARK: - Settings

    /// Where JPEGs go: a folder chosen in Settings, else `Exports` inside the library.
    @Published var exportFolder: URL? = UserDefaults.standard.string(forKey: "exportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } {
        didSet {
            defaults.set(exportFolder?.path, forKey: "exportFolder")
            LibraryPaths.customExportsDir = exportFolder
            library.refreshExportedJPEGs()
        }
    }
    @Published var jpegQuality: Double = UserDefaults.standard.object(forKey: "jpegQuality") as? Double ?? 0.92 {
        didSet { defaults.set(jpegQuality, forKey: "jpegQuality") }
    }
    @Published var revealAfterExport: Bool = UserDefaults.standard.object(forKey: "revealAfterExport") as? Bool ?? true {
        didSet { defaults.set(revealAfterExport, forKey: "revealAfterExport") }
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "Exported JPEGs are written to this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = library.paths.exportsDir
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.exportFolder = url
        }
    }

    private let defaults = UserDefaults.standard

    // MARK: - Navigation

    var editingPhoto: Photo? { editingID.flatMap { library.photo(id: $0) } }

    func open(_ id: Photo.ID) { editingID = id; selection = [id]; cropMode = false }
    func closeEditor() {
        if let id = editingID { renders.enqueue([id], front: true) }   // make sure the thumbnail reflects the edit
        editingID = nil
        cropMode = false
    }
    func step(_ delta: Int) { if let next = neighbour(delta) { goTo(next) } }
    func canStep(_ delta: Int) -> Bool { neighbour(delta) != nil }
    /// The next (or previous) photo among the visible ones. A photo that is no longer visible (unflagged
    /// under the flagged-only filter) steps to the nearest visible one in library order.
    func neighbour(_ delta: Int) -> Photo.ID? {
        guard let id = editingID, delta != 0 else { return nil }
        let visible = orderedPhotos
        if let i = visible.firstIndex(where: { $0.id == id }) {
            let j = i + delta
            return visible.indices.contains(j) ? visible[j].id : nil
        }
        guard let k = library.photos.firstIndex(where: { $0.id == id }) else { return nil }
        let shown = Set(visible.map(\.id))
        let rest = delta > 0 ? Array(library.photos[(k + 1)...]) : Array(library.photos[..<k].reversed())
        return rest.first { shown.contains($0.id) }?.id
    }
    /// Open another photo from the editor; the one being left gets its thumbnail refreshed.
    func goTo(_ id: Photo.ID) {
        guard id != editingID else { return }
        if let current = editingID { renders.enqueue([current], front: true) }
        open(id)
    }

    // MARK: - Flags and presets

    /// What a Photo-menu command acts on: the photo being edited, else the selection.
    var targetIDs: Set<Photo.ID> { editingID.map { [$0] } ?? selection }
    private func targets(_ ids: Set<Photo.ID>?) -> [Photo] { let ids = ids ?? targetIDs; return library.photos.filter { ids.contains($0.id) } }
    var targetsAllFlagged: Bool { let t = targets(nil); return !t.isEmpty && t.allSatisfy(\.flagged) }
    /// Flag the photos, or unflag them when every one is flagged already (P).
    func toggleFlag(_ ids: Set<Photo.ID>? = nil) {
        let t = targets(ids)
        guard !t.isEmpty else { return }
        library.setFlag(!t.allSatisfy(\.flagged), ids: Set(t.map(\.id)))
    }
    func unflag(_ ids: Set<Photo.ID>? = nil) { library.setFlag(false, ids: Set(targets(ids).map(\.id))) }
    /// The rating all the targets share, or nil when they differ.
    var targetsRating: Int? { let r = Set(targets(nil).map(\.rating)); return r.count == 1 ? r.first : nil }
    func setRating(_ stars: Int, _ ids: Set<Photo.ID>? = nil) { library.setRating(stars, ids: Set(targets(ids).map(\.id))) }

    /// Tags: add (several, comma-separated), remove, and the "New Tag…" prompt.
    func addTags(_ text: String, to ids: Set<Photo.ID>? = nil) {
        let ids = Set(targets(ids).map(\.id))
        for t in Photo.parseTags(text) { library.addTag(t, ids: ids) }
    }
    func removeTag(_ tag: String, from ids: Set<Photo.ID>? = nil) { library.removeTag(tag, ids: Set(targets(ids).map(\.id))) }
    func targetsHaveTag(_ tag: String, _ ids: Set<Photo.ID>? = nil) -> Bool { let t = targets(ids); return !t.isEmpty && t.allSatisfy { $0.hasTag(tag) } }
    @Published var askNewTag = false
    private(set) var newTagTargets: Set<Photo.ID> = []
    func promptNewTag(_ ids: Set<Photo.ID>? = nil) {
        newTagTargets = Set(targets(ids).map(\.id))
        guard !newTagTargets.isEmpty else { return }
        askNewTag = true
    }

    struct PresetCommand: Equatable { let preset: Preset; let serial: Int }
    /// A preset for the editor to apply to the photo it is showing (its live settings).
    @Published var presetCommand: PresetCommand?
    private var presetSerial = 0
    /// The editor shows its "name this preset" prompt.
    @Published var askPresetName = false

    /// Apply a preset's adjustments to photos; their crop and orientation stay.
    func applyPreset(_ preset: Preset, to ids: Set<Photo.ID>? = nil) {
        let ids = ids ?? targetIDs
        var rest = ids
        if let e = editingID, ids.contains(e) {
            presetSerial += 1; presetCommand = PresetCommand(preset: preset, serial: presetSerial)
            rest.remove(e)
        }
        for id in rest { if let p = library.photo(id: id) { library.setSettings(p.settings.applying(preset), for: id) } }
        renders.enqueue(Array(rest), front: true)
    }

    // MARK: - Import

    func importViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Sigma Photos"
        panel.message = "Choose X3F files or folders. They are copied into the library, organised by capture date."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "x3f") ?? .data, .folder]
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            Task { await self.importURLs(panel.urls) }
        }
    }

    func importURLs(_ urls: [URL]) async {
        guard library.importProgress == nil else { return }
        let ids = await library.importItems(urls)
        renders.enqueue(ids)
        tagging.enqueue(ids)
    }

    // MARK: - Export

    var exportCandidates: [Photo] {
        if let p = editingPhoto { return [p] }
        return library.photos.filter { selection.contains($0.id) }
    }

    func exportSelected(to folder: URL? = nil) {
        let photos = exportCandidates
        guard !photos.isEmpty, exportProgress == nil else { return }
        let dest = folder ?? library.paths.exportsDir
        exportProgress = ExportProgress(done: 0, total: photos.count, name: "")
        Task {
            defer { exportProgress = nil }
            do {
                let files = try await renders.export(photos, to: dest, quality: jpegQuality) { [weak self] done, total, name in
                    self?.exportProgress = ExportProgress(done: done, total: total, name: name)
                }
                if !files.isEmpty, revealAfterExport { NSWorkspace.shared.activateFileViewerSelecting(files) }
            } catch {
                alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    func exportViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Export JPEG"
        panel.message = "Choose a folder for the JPEG files."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = library.paths.exportsDir
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.exportSelected(to: url)
        }
    }

    /// Render JPEGs to a temporary folder and hand them to the system share sheet.
    func share(anchor: NSView) {
        let photos = exportCandidates
        guard !photos.isEmpty, exportProgress == nil else { return }
        let dir = library.paths.tmpDir.appendingPathComponent("share-\(UUID().uuidString.prefix(6))", isDirectory: true)
        exportProgress = ExportProgress(done: 0, total: photos.count, name: "")
        Task {
            defer { exportProgress = nil }
            do {
                let files = try await renders.export(photos, to: dir, quality: jpegQuality) { [weak self] done, total, name in
                    self?.exportProgress = ExportProgress(done: done, total: total, name: name)
                }
                guard !files.isEmpty else { return }
                let picker = NSSharingServicePicker(items: files)
                picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            } catch {
                alert = AlertInfo(title: "Share failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Library management

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Library Folder"
        panel.message = "Imported photos are organised by date inside this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = library.paths.root
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.editingID = nil; self.selection = []
            self.tagging.stop()
            self.library.changeRoot(to: url)
            self.renders.updatePaths(self.library.paths)
            self.tagging.enqueueMissing()
        }
    }

    func revealLibrary() { NSWorkspace.shared.activateFileViewerSelecting([library.paths.root]) }
    func revealExports() {
        try? FileManager.default.createDirectory(at: library.paths.exportsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.paths.exportsDir])
    }

    func removeSelected() {
        let ids = editingID.map { Set([$0]) } ?? selection
        guard !ids.isEmpty else { return }
        pendingRemoval = ids
    }

    func confirmRemoval(deleteFiles: Bool) {
        guard let ids = pendingRemoval else { return }
        pendingRemoval = nil
        if editingID.map(ids.contains) == true { editingID = nil }
        selection.subtract(ids)
        library.remove(ids: ids, deleteFiles: deleteFiles)
    }

    func rerenderSelected() {
        let ids = editingID.map { [$0] } ?? Array(selection)
        for id in ids { if let p = library.photo(id: id) { try? FileManager.default.removeItem(at: library.paths.renderDir(p)); library.setPreviewKey(nil, for: id) } }
        renders.enqueue(ids, front: true)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var name: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// For `.preferredColorScheme`; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Handles files opened from the Finder (double-click or drop on the icon) and app termination.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?
    func application(_ application: NSApplication, open urls: [URL]) {
        let callbacks = urls.filter { $0.scheme?.lowercased() == Blank.callbackURL.scheme }
        let files = urls.filter { $0.isFileURL }
        Task { @MainActor in
            for u in callbacks { AppDelegate.state?.blank.handleCallback(u) }
            if !files.isEmpty { await AppDelegate.state?.importURLs(files) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.state?.library.saveNow()
        }
    }
}
