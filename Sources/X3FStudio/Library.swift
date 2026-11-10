import Foundation
import AppKit
import Combine

/// The photo library: catalog, import, and the per-photo settings.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var paths: LibraryPaths
    @Published private(set) var photos: [Photo] = []
    /// The local model's title and summary per day, keyed by `dayKey`.
    @Published private(set) var sessions: [String: SessionInfo] = [:]
    @Published var importProgress: ImportProgress?
    @Published var lastImportSummary: String?
    @Published var errorMessage: String?

    struct ImportProgress { var done: Int; var total: Int; var currentName: String }

    private var saveTask: Task<Void, Never>?
    private static let rootKey = "libraryRoot"
    /// Set when the catalog on disk exists but could not be decoded: saving is disabled so it survives.
    private(set) var loadFailed = false
    /// Saved adjustment sets (see `Preset`), kept in the library's data folder.
    @Published private(set) var presets: [Preset] = []
    /// The user's presets followed by the built-in ones.
    var allPresets: [Preset] { presets + Preset.builtIn }
    /// Base names (lower-cased, no extension) of the JPEGs in the library's Exports folder.
    @Published private(set) var exportedJPEGs: Set<String> = []

    init() {
        let stored = UserDefaults.standard.string(forKey: Library.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        paths = LibraryPaths(root: stored ?? LibraryPaths.defaultRoot)
        open()
    }

    // MARK: - Catalog

    private func open() {
        do { try paths.createDirectories() } catch { errorMessage = "Cannot create the library folder at \(paths.root.path): \(error.localizedDescription)" }
        photos = []
        sessions = [:]
        loadFailed = false
        if let data = try? Data(contentsOf: paths.catalogURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            do { let cat = try dec.decode(Catalog.self, from: data); photos = cat.photos; sessions = cat.sessions } catch {
                // never let a catalog this build cannot read be overwritten by an empty one
                loadFailed = true
                errorMessage = "The library catalog could not be read (\(error.localizedDescription)). Nothing will be saved until it can."
            }
        }
        // drop entries whose original vanished, keep the catalog honest
        photos.removeAll { !FileManager.default.fileExists(atPath: paths.original($0).path) }
        // files imported before an engine existed for them (older catalogs only knew "Quattro or not")
        var relabelled = false
        for i in photos.indices where photos[i].engine == .unsupported {
            if let k = X3FFile.probeEngineKind(at: paths.original(photos[i])), k != photos[i].engine { photos[i].engine = k; relabelled = true }
        }
        sortPhotos()
        // crops from the first crop tool were kept in sensor pixels; the frame crop lives in the upright frame
        for i in photos.indices {
            guard var e = photos[i].edited, let old = e.crop else { continue }
            e.crop = nil
            if e.frameCrop == nil, photos[i].sensorWidth > 0 { e.frameCrop = CropRect(photos[i].geometry(for: e).toDisplay(old), in: photos[i].geometry(for: e).display) }
            photos[i].edited = e; relabelled = true
        }
        if relabelled { scheduleSave() }
        fillFrameGeometry()
        loadPresets()
        refreshExportedJPEGs()
    }

    /// Re-read the Exports folder (at open, and after an export).
    func refreshExportedJPEGs() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.exportsDir.path)) ?? []
        exportedJPEGs = Set(names.filter { ["jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }.map { ($0 as NSString).deletingPathExtension.lowercased() })
    }
    /// The photo's JPEG in the Exports folder, if there is one.
    func exportedJPEG(_ p: Photo) -> URL? {
        let base = (p.fileName as NSString).deletingPathExtension
        guard exportedJPEGs.contains(base.lowercased()) else { return nil }
        return paths.exportsDir.appendingPathComponent(base + ".jpg")
    }

    /// Catalogs written before cropping existed lack the sensor frame and the camera crop; read them
    /// from the file headers once, off the main thread, and save.
    private func fillFrameGeometry() {
        let todo = photos.filter { $0.sensorWidth == 0 && $0.engine.isSupported }.map { ($0.id, paths.original($0)) }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var found: [(Photo.ID, CGSize, CropRect?)] = []
            for (id, url) in todo {
                guard let x = try? X3FFile(url: url) else { continue }
                found.append((id, x.sensorSize, x.cameraCrop))
            }
            let results = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, size, crop) in results {
                    guard let i = self.photos.firstIndex(where: { $0.id == id }) else { continue }
                    self.photos[i].sensorWidth = Int(size.width); self.photos[i].sensorHeight = Int(size.height); self.photos[i].cameraCrop = crop
                }
                if !results.isEmpty { self.scheduleSave() }
            }
        }
    }

    func changeRoot(to url: URL) {
        UserDefaults.standard.set(url.path, forKey: Library.rootKey)
        paths = LibraryPaths(root: url)
        open()
    }

    private func sortPhotos() {
        photos.sort { a, b in a.captureDate != b.captureDate ? a.captureDate > b.captureDate : a.fileName > b.fileName }
    }

    private func scheduleSave() {
        Debug.tick("library.save")
        guard !loadFailed else { return }
        saveTask?.cancel()
        let snapshot = Catalog(photos: photos, sessions: sessions)
        let url = paths.catalogURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func saveNow() {
        guard !loadFailed else { return }
        saveTask?.cancel()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Catalog(photos: photos, sessions: sessions)) { try? data.write(to: paths.catalogURL, options: .atomic) }
    }

    func photo(id: Photo.ID) -> Photo? { photos.first { $0.id == id } }

    func update(_ photo: Photo) {
        guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        if photos[i] != photo { photos[i] = photo; scheduleSave() }
    }

    func setSettings(_ s: SPPSettings?, for id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let q = s?.quantized()
        let new = (q == photos[i].asShot) ? nil : q
        if photos[i].edited != new { photos[i].edited = new; scheduleSave() }
    }

    func remove(ids: Set<Photo.ID>, deleteFiles: Bool) {
        let fm = FileManager.default
        for p in photos where ids.contains(p.id) {
            if deleteFiles { try? fm.trashItem(at: paths.original(p), resultingItemURL: nil) }
            try? fm.removeItem(at: paths.thumb(p)); try? fm.removeItem(at: paths.preview(p)); try? fm.removeItem(at: paths.renderDir(p))
        }
        photos.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func setPreviewKey(_ key: String?, for id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }), photos[i].previewKey != key else { return }
        photos[i].previewKey = key; scheduleSave()
    }

    func markExported(_ id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].exportedAt = Date(); photos[i].exportedSettings = photos[i].settings.quantized(); scheduleSave()
        refreshExportedJPEGs()
    }

    /// Every tag in the library with how many photos carry it, most used first.
    var allTags: [(tag: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for p in photos {
            var seen = Set<String>()
            for t in p.tags + p.aiTags {
                let k = t.lowercased()
                guard !seen.contains(k) else { continue }
                seen.insert(k); counts[k] = (counts[k]?.0 ?? t, (counts[k]?.1 ?? 0) + 1)
            }
        }
        return counts.values
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (tag: $0.0, count: $0.1) }
    }

    func addTag(_ tag: String, ids: Set<Photo.ID>) {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let spelling = allTags.first { $0.tag.caseInsensitiveCompare(t) == .orderedSame }?.tag ?? t   // one spelling per tag
        var changed = false
        for i in photos.indices where ids.contains(photos[i].id) && !photos[i].hasTag(spelling) {
            photos[i].tags.append(spelling)
            photos[i].tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            changed = true
        }
        if changed { scheduleSave() }
    }

    func removeTag(_ tag: String, ids: Set<Photo.ID>) {
        var changed = false
        for i in photos.indices where ids.contains(photos[i].id) {
            let n = photos[i].tags.count + photos[i].aiTags.count
            photos[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            photos[i].aiTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if photos[i].tags.count + photos[i].aiTags.count != n { changed = true }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Local model results

    /// A day's key for sessions: the capture day in the local calendar, "2026-11-07".
    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func session(forKey key: String) -> SessionInfo? { sessions[key] }
    func setSession(_ info: SessionInfo, forKey key: String) { sessions[key] = info; scheduleSave() }

    func setAI(_ notes: TaggingService.PhotoNotes, model: String, for id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].aiCaption = notes.caption; photos[i].aiCategories = notes.categories; photos[i].aiTags = notes.tags
        photos[i].aiMood = notes.mood; photos[i].aiModel = model; photos[i].aiAt = Date()
        scheduleSave()
    }
    func setAdvice(_ advice: PhotoAdvice?, for id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].aiAdvice = advice; scheduleSave()
    }
    /// The suggestion was applied or dismissed: keep the note, drop the flag.
    func settleAdvice(for id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }), var a = photos[i].aiAdvice else { return }
        a.needsWork = false; photos[i].aiAdvice = a; scheduleSave()
    }

    func removeAITag(_ tag: String, from id: Photo.ID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].aiTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        scheduleSave()
    }
    func clearSessions() { sessions = [:]; scheduleSave() }
    /// Forget everything the model said (before a run with another model).
    func clearAI() {
        for i in photos.indices { photos[i].aiCaption = nil; photos[i].aiCategories = []; photos[i].aiTags = []; photos[i].aiMood = nil; photos[i].aiModel = nil; photos[i].aiAt = nil; photos[i].aiAdvice = nil }
        sessions = [:]
        scheduleSave()
    }

    func markPublished(_ ref: BlankPostRef, ids: Set<Photo.ID>) {
        for i in photos.indices where ids.contains(photos[i].id) { photos[i].blankPost = ref }
        scheduleSave()
    }

    func setRating(_ stars: Int, ids: Set<Photo.ID>) {
        let stars = min(5, max(0, stars))
        var changed = false
        for i in photos.indices where ids.contains(photos[i].id) && photos[i].rating != stars { photos[i].rating = stars; changed = true }
        if changed { scheduleSave() }
    }

    func setFlag(_ on: Bool, ids: Set<Photo.ID>) {
        var changed = false
        for i in photos.indices where ids.contains(photos[i].id) && photos[i].flagged != on { photos[i].flagged = on; changed = true }
        if changed { scheduleSave() }
    }

    // MARK: - Presets

    private func loadPresets() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: paths.presetsURL), let file = try? dec.decode(PresetFile.self, from: data) { presets = file.presets } else { presets = [] }
    }

    private func savePresets() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(PresetFile(presets: presets)) { try? data.write(to: paths.presetsURL, options: .atomic) }
    }

    @discardableResult
    func addPreset(name: String, adjustments: SPPSettings) -> Preset {
        let p = Preset(name: name, adjustments: adjustments.adjustments)
        presets.append(p)
        savePresets()
        return p
    }

    func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    // MARK: - Grouping

    struct DayGroup: Identifiable { let id: Date; let title: String; let photos: [Photo]; let key: String; let session: SessionInfo? }

    var dayGroups: [DayGroup] { dayGroups(photos) }
    func dayGroups(_ photos: [Photo]) -> [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: photos) { cal.startOfDay(for: $0.captureDate) }
        let fmt = DateFormatter(); fmt.dateStyle = .full; fmt.timeStyle = .none
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(id: day, title: fmt.string(from: day), photos: grouped[day]!.sorted { $0.captureDate < $1.captureDate },
                     key: Library.dayKey(for: day), session: sessions[Library.dayKey(for: day)])
        }
    }

    // MARK: - Import

    /// Import files and folders: every X3F found is copied into `YYYY/YYYY-MM-DD/` by capture date.
    /// Returns the ids of the newly imported photos.
    @discardableResult
    func importItems(_ urls: [URL]) async -> [Photo.ID] {
        let files = await Task.detached(priority: .userInitiated) { Library.collectX3Fs(urls) }.value
        guard !files.isEmpty else { lastImportSummary = "No X3F files found."; return [] }
        importProgress = ImportProgress(done: 0, total: files.count, currentName: "")
        defer { importProgress = nil }

        var imported: [Photo.ID] = []
        var skippedDuplicates = 0
        var failed: [String] = []
        var known = Set(photos.map(\.id))
        var knownKeys = Set(photos.map(\.duplicateKey))
        let paths = self.paths

        for (i, file) in files.enumerated() {
            importProgress = ImportProgress(done: i, total: files.count, currentName: file.lastPathComponent)
            let knownNow = known, knownKeysNow = knownKeys
            let result: Result<Photo, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let x = try X3FFile(url: file)
                    if knownNow.contains(x.uniqueID) { throw ImportError.duplicate }
                    let key = "\(file.lastPathComponent.lowercased())|\(x.fileSize)|\(Int((x.captureDate ?? Date()).timeIntervalSince1970))"
                    if knownKeysNow.contains(key) { throw ImportError.duplicate }
                    return .success(try Library.ingest(x, into: paths))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let photo):
                known.insert(photo.id); knownKeys.insert(photo.duplicateKey)
                photos.append(photo)
                imported.append(photo.id)
            case .failure(let e):
                if case ImportError.duplicate = e { skippedDuplicates += 1 }
                else { failed.append("\(file.lastPathComponent): \(e.localizedDescription)") }
            }
            if i % 5 == 0 { sortPhotos() }
        }
        sortPhotos()
        saveNow()
        var parts = ["Imported \(imported.count) photo\(imported.count == 1 ? "" : "s")"]
        if skippedDuplicates > 0 { parts.append("\(skippedDuplicates) already in the library") }
        if !failed.isEmpty { parts.append("\(failed.count) failed (\(failed.prefix(2).joined(separator: "; ")))") }
        lastImportSummary = parts.joined(separator: " · ")
        return imported
    }

    enum ImportError: LocalizedError {
        case duplicate, copyFailed(String)
        var errorDescription: String? {
            switch self {
            case .duplicate: return "Already in the library"
            case .copyFailed(let m): return "Copy failed: \(m)"
            }
        }
    }

    nonisolated static func collectX3Fs(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e where f.pathExtension.lowercased() == "x3f" { out.append(f) }
                }
            } else if url.pathExtension.lowercased() == "x3f" {
                out.append(url)
            }
        }
        // stable order: by path
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Copy one X3F into its date folder and build its catalog entry + camera-JPEG thumbnail.
    nonisolated static func ingest(_ x: X3FFile, into paths: LibraryPaths) throws -> Photo {
        let fm = FileManager.default
        let date = x.captureDate ?? Date()
        let folder = paths.dayFolder(for: date)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var dest = folder.appendingPathComponent(x.url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            // same name, different file: keep both
            let base = x.url.deletingPathExtension().lastPathComponent, ext = x.url.pathExtension
            var n = 2
            repeat { dest = folder.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1 } while fm.fileExists(atPath: dest.path)
        }
        if dest.standardizedFileURL != x.url.standardizedFileURL {
            do { try fm.copyItem(at: x.url, to: dest) } catch { throw ImportError.copyFailed(error.localizedDescription) }
        }
        let rel = dest.path.replacingOccurrences(of: paths.root.path + "/", with: "")
        let size = x.developedSize
        let photo = Photo(id: x.uniqueID, relativePath: rel, fileName: dest.lastPathComponent, captureDate: date, importedAt: Date(),
                          pixelWidth: Int(size.width), pixelHeight: Int(size.height), rotation: x.rotation,
                          camera: x.camera, asShot: x.asShot, edited: nil, engine: x.engineKind, fileSize: x.fileSize,
                          sensorWidth: Int(x.sensorSize.width), sensorHeight: Int(x.sensorSize.height), cameraCrop: x.cameraCrop)
        // instant thumbnail from the camera's own JPEG; replaced by the engine's rendering later
        if let thumb = x.embeddedThumbnail(maxPixel: 640) {
            thumb.writeJPEG(to: paths.thumb(photo), quality: 0.85)
        }
        if let preview = x.embeddedThumbnail(maxPixel: 2048) {
            preview.writeJPEG(to: paths.preview(photo), quality: 0.88)
        }
        return photo
    }
}
