import Foundation
import AppKit
import Combine
import os

/// Coordinates the engine servers: one for the editor's quick renders (never blocked), one for its
/// full-quality finals, one grinding through background renders (import previews, batch export).
/// Owns the caches. The finals get their own server because the Quattro engine re-renders a 16-bit
/// master incrementally (~50 ms instead of ~3 s) only when its previous request was another 16-bit
/// master of the same image; quick renders in between would reset it.
@MainActor
final class RenderService: ObservableObject {
    let interactive: EngineServer
    let final: EngineServer
    let background: EngineServer
    private(set) var paths: LibraryPaths
    /// The photo's own Temperature/Tint when set; otherwise the camera's colour, untouched (the engine's
    /// own default). The grid cells behave alike in both engines (measured on the Merrill engine,
    /// 9 Nov 2026: per grid unit about +0.026/−0.021 stops on R/G and B/G along the temperature axis,
    /// −0.027/−0.025 along tint, against the Quattro model's ±0.03).
    func look(for photo: Photo, settings: SPPSettings) -> SPPColorAdjustment { settings.colorAdjustment ?? SPPColorAdjustment() }
    /// The engine develops the sensor region that covers the crop (after turns and straightening).
    func frame(for photo: Photo, settings: SPPSettings) -> EngineServer.Frame {
        let r = photo.engineRegion(for: settings)
        return r == photo.fullFrame ? .full : .trim(r)
    }

    /// What the thumbnail and preview of `photo` should have been made from: the name of its current
    /// master (settings, developed region, colour adjustment and engine version all in it).
    func derivativeKey(for photo: Photo) -> String { paths.render(photo, settings: photo.settings, look: look(for: photo, settings: photo.settings)).lastPathComponent }

    @Published var backgroundTotal = 0
    @Published var backgroundDone = 0
    @Published var engineError: String?
    /// Bumped whenever a thumbnail/preview file changes, so views reload.
    @Published var derivativesVersion = 0

    private var queue: [Photo.ID] = []
    private var queued: Set<Photo.ID> = []
    private var worker: Task<Void, Never>?
    weak var library: Library?
    private static let log = Logger(subsystem: "com.maybethis.x3fstudio", category: "render")

    init(paths: LibraryPaths) {
        self.paths = paths
        interactive = EngineServer(name: "interactive", tmpDir: paths.tmpDir.appendingPathComponent("interactive"), logURL: paths.logsDir.appendingPathComponent("engine-interactive.log"))
        final = EngineServer(name: "final", tmpDir: paths.tmpDir.appendingPathComponent("final"), logURL: paths.logsDir.appendingPathComponent("engine-final.log"))
        background = EngineServer(name: "background", tmpDir: paths.tmpDir.appendingPathComponent("background"), logURL: paths.logsDir.appendingPathComponent("engine-background.log"))
    }

    func updatePaths(_ p: LibraryPaths) {
        paths = p
        queue.removeAll(); queued.removeAll(); backgroundTotal = 0; backgroundDone = 0
    }

    var isBackgroundBusy: Bool { backgroundDone < backgroundTotal }

    // MARK: - Interactive

    /// Quick-display render for the editor: the developed region (or the whole frame for the crop
    /// tool) in sensor orientation, to be turned and cropped with `EngineImage.composed`.
    func quickRender(_ photo: Photo, settings: SPPSettings, maxDevicePixels: CGSize, wholeFrame: Bool = false) async throws -> EngineImage {
        let region = wholeFrame ? photo.fullFrame : photo.engineRegion(for: settings)
        let size = quickSize(for: photo, settings: settings, fitting: maxDevicePixels, wholeFrame: wholeFrame)
        let out = paths.quickDir.appendingPathComponent("\(photo.id)-\(UUID().uuidString.prefix(8)).rgb8")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await interactive.render(file: paths.original(photo), settings: settings, mode: .quick(width: size.w, height: size.h), engine: photo.engine,
                                             look: look(for: photo, settings: settings), frame: wholeFrame ? .full : frame(for: photo, settings: settings), output: out)
        guard let img = RawImage.cgImage(rgb8: out, width: r.width, height: r.height, rotation: 0) else {
            throw EngineServer.Failure.badReply
        }
        RenderService.log.info("quick \(r.width)×\(r.height) (view \(Int(maxDevicePixels.width))×\(Int(maxDevicePixels.height))): engine \(Int(r.engineMillis)) ms")
        return EngineImage(image: img, region: region, scale: CGFloat(r.width) / CGFloat(max(1, region.width)))
    }

    /// The finished image for a photo + settings from its 16-bit master: turned, flipped, straightened
    /// and cropped. `maxPixel` limits the longer side.
    nonisolated static func finalImage(photo: Photo, settings: SPPSettings, tiff: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let raw = RawImage.cgImage(tiff: tiff, applyOrientation: false) else { return nil }
        let region = photo.engineRegion(for: settings)
        let e = EngineImage(image: raw, region: region, scale: CGFloat(raw.width) / CGFloat(max(1, region.width)))
        let crop = photo.frameCrop(for: settings)
        var target = e.scale
        if let m = maxPixel { target = min(target, CGFloat(m) / max(1, max(crop.width, crop.height))) }
        return e.composed(geometry: photo.geometry(for: settings), straighten: settings.straighten, crop: crop, targetScale: target)
    }

    /// Size for the quick render: the photo as it is shown, i.e. fitted into `px` (the image area in
    /// device pixels), in sensor orientation, rounded up to even numbers. SIGMA Photo Pro asks
    /// designation 0 for exactly its review size, and at such sizes our output matches SPP's pixel
    /// for pixel (SDIM0431 at 838 × 559 and 996 × 664). Measured on that file (9 Nov 2026): up to
    /// about two thirds of the native half size the Quattro quick path's chroma noise in flat sky is
    /// at or below the 16-bit master's at the same scale; towards exactly half it rises to 5× of it
    /// (the "chroma dots"), so Quattro requests are capped at a third of the frame instead of being
    /// smoothed. The Merrill quick path is clean at half, so it may use the whole range.
    func quickSize(for photo: Photo, settings: SPPSettings, fitting px: CGSize, wholeFrame: Bool = false) -> (w: Int, h: Int) {
        // the developed region in sensor orientation, at the scale that makes what is shown (the whole
        // upright frame for the crop tool, else the crop) fit the view
        let region = wholeFrame ? photo.fullFrame : photo.engineRegion(for: settings)
        let sw = CGFloat(region.width), sh = CGFloat(region.height)
        let shown = wholeFrame ? photo.geometry(for: settings).display : photo.frameCrop(for: settings).size
        var scale = min(px.width / max(1, shown.width), px.height / max(1, shown.height))
        if !scale.isFinite || scale <= 0 { scale = 1 }
        scale = min(scale, photo.engine == .quattro ? 1.0 / 3.0 : 0.5)
        func even(_ v: CGFloat) -> Int { max(64, (Int(v.rounded(.up)) + 1) & ~1) }
        return (even(sw * scale), even(sh * scale))
    }

    /// Full-quality 16-bit master for a photo + settings (cached on disk). The editor's finals go to
    /// the `final` server; the background queue and exports pass `background`. A master that is
    /// already being developed (by any server) is awaited rather than developed twice: two servers
    /// writing the same file at once would interleave their output.
    func fullRender(_ photo: Photo, settings: SPPSettings, on server: EngineServer? = nil) async throws -> URL {
        let url = paths.render(photo, settings: settings, look: look(for: photo, settings: settings))
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if RenderService.isValidMaster(url) {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // LRU touch
                return url
            }
            // not a TIFF (masters written while the Quattro engine was clobbering the server's frame,
            // 10 Nov 2026, are headerless pixel dumps): develop it again
            RenderService.log.error("discarding unreadable master \(url.lastPathComponent, privacy: .public)")
            try? fm.removeItem(at: url)
        }
        if let running = inFlight[url] { return try await running.value }
        let engine = server ?? final
        let original = paths.original(photo), kind = photo.engine, look = look(for: photo, settings: settings), frame = frame(for: photo, settings: settings)
        let job = Task { [paths] () throws -> URL in
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.appendingPathExtension(String(UUID().uuidString.prefix(8)) + ".part")
            _ = try await engine.render(file: original, settings: settings, mode: .full, engine: kind, look: look, frame: frame, output: tmp)
            guard RenderService.isValidMaster(tmp) else {
                try? fm.removeItem(at: tmp)
                throw EngineServer.Failure.failed("The engine returned an unreadable full-quality image")
            }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
            Task.detached(priority: .utility) { RenderService.evictRenders(paths, keepBytes: 3 << 30) }
            return url
        }
        inFlight[url] = job
        defer { inFlight[url] = nil }
        return try await job.value
    }
    private var inFlight: [URL: Task<URL, Error>] = [:]

    /// A master is a 16-bit TIFF the server wrote: little-endian TIFF magic and more than a header.
    nonisolated static func isValidMaster(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8), head.count == 8 else { return false }
        return head.starts(with: [0x49, 0x49, 0x2A, 0x00])
    }

    /// Rebuild the grid thumbnail and the editor's placeholder preview from a full render.
    func updateDerivatives(for photo: Photo, from tiff: URL) async {
        let thumbURL = paths.thumb(photo), previewURL = paths.preview(photo)
        let settings = photo.settings
        let written = await Task.detached(priority: .utility) { () -> Bool in
            guard let preview = RenderService.finalImage(photo: photo, settings: settings, tiff: tiff, maxPixel: 2048) else { return false }
            preview.writeJPEG(to: previewURL, quality: 0.88)
            if let thumb = RawImage.downscaled(preview, maxPixel: 640) { thumb.writeJPEG(to: thumbURL, quality: 0.85) }
            return true
        }.value
        guard written else { return }   // the key says "made from these settings": only when they were
        library?.setPreviewKey(derivativeKey(for: photo), for: photo.id)
        derivativesVersion &+= 1
    }

    nonisolated static func evictRenders(_ paths: LibraryPaths, keepBytes: Int) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: paths.rendersDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let modified = v.contentModificationDate ?? .distantPast
            // a render that was interrupted (the app quit, a slider moved on) leaves its ".part" behind
            if f.pathExtension == "part" { if modified < Date(timeIntervalSinceNow: -900) { try? fm.removeItem(at: f) }; continue }
            guard f.pathExtension == "tif" else { continue }
            files.append((f, v.fileSize ?? 0, modified))
        }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > keepBytes {
            try? fm.removeItem(at: url); total -= size
        }
    }

    // MARK: - Background queue

    /// Render these photos' current settings in the background and refresh their thumbnails.
    func enqueue(_ ids: [Photo.ID], front: Bool = false) {
        let fresh = ids.filter { !queued.contains($0) }
        guard !fresh.isEmpty else { return }
        for id in fresh { queued.insert(id) }
        if front { queue.insert(contentsOf: fresh, at: 0) } else { queue.append(contentsOf: fresh) }
        if backgroundDone >= backgroundTotal { backgroundTotal = 0; backgroundDone = 0 }
        backgroundTotal += fresh.count
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runQueue()
            self?.worker = nil
        }
    }

    private func runQueue() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            defer { queued.remove(id); backgroundDone += 1 }
            guard let library, let photo = library.photo(id: id), photo.engine.isSupported else { continue }
            if photo.previewKey == derivativeKey(for: photo) { continue }   // thumbnail and preview already made from these settings
            do {
                let tiff = try await fullRender(photo, settings: photo.settings, on: background)
                await updateDerivatives(for: photo, from: tiff)
                engineError = nil
            } catch {
                engineError = error.localizedDescription
                if case EngineServer.Failure.notInstalled = error { queue.removeAll(); queued.removeAll(); backgroundDone = backgroundTotal - 1 }
            }
        }
    }

    // MARK: - Export

    /// Export full-size JPEGs into `folder`. Returns the written files.
    func export(_ photos: [Photo], to folder: URL, quality: Double = 0.92, progress: @MainActor (Int, Int, String) -> Void) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for (i, photo) in photos.enumerated() {
            progress(i, photos.count, photo.fileName)   // synchronous on the main actor, so it can't outlive the caller's cleanup
            let dest = folder.appendingPathComponent(photo.fileName).deletingPathExtension().appendingPathExtension("jpg")
            if photo.engine.isSupported {
                let tiff = try await fullRender(photo, settings: photo.settings, on: background)
                let settings = photo.settings
                guard let img = await Task.detached(priority: .userInitiated, operation: { RenderService.finalImage(photo: photo, settings: settings, tiff: tiff) }).value else {
                    throw NSError(domain: "X3FStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read the rendered image"])
                }
                try JPEGExport.write(image: img, to: dest, photo: photo, original: paths.original(photo), quality: quality)
                await updateDerivatives(for: photo, from: tiff)
            } else {
                // files no engine here develops (X3F 2.x cameras): export the camera's own JPEG.
                guard let x = try? X3FFile(url: paths.original(photo)), let up = x.embeddedThumbnail(maxPixel: nil) else { continue }
                var props = JPEGExport.metadata(for: photo, original: paths.original(photo))
                props[kCGImagePropertyDPIWidth] = 300; props[kCGImagePropertyDPIHeight] = 300
                up.writeJPEG(to: dest, quality: quality, properties: props)
            }
            written.append(dest)
            library?.markExported(photo.id)
        }
        return written
    }

    func shutdown() async {
        await interactive.shutdown()
        await final.shutdown()
        await background.shutdown()
    }
}
