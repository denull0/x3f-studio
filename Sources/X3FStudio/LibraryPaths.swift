import Foundation

/// Where everything lives. Originals are organised by capture date directly in the
/// library folder (`2026/2026-11-07/SDIM0457.X3F`); the app's own data is in `.x3fstudio`.
struct LibraryPaths {
    let root: URL

    var dataDir: URL { root.appendingPathComponent(".x3fstudio", isDirectory: true) }
    var catalogURL: URL { dataDir.appendingPathComponent("catalog.json") }
    var presetsURL: URL { dataDir.appendingPathComponent("presets.json") }
    var thumbsDir: URL { dataDir.appendingPathComponent("thumbs", isDirectory: true) }
    var previewsDir: URL { dataDir.appendingPathComponent("previews", isDirectory: true) }
    var rendersDir: URL { dataDir.appendingPathComponent("renders", isDirectory: true) }
    var quickDir: URL { dataDir.appendingPathComponent("quick", isDirectory: true) }
    var logsDir: URL { dataDir.appendingPathComponent("logs", isDirectory: true) }
    var tmpDir: URL { dataDir.appendingPathComponent("tmp", isDirectory: true) }
    /// A folder chosen in Settings for JPEG exports; nil = `Exports` inside the library.
    static var customExportsDir: URL?
    var exportsDir: URL { LibraryPaths.customExportsDir ?? root.appendingPathComponent("Exports", isDirectory: true) }

    static var defaultRoot: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("X3F Studio", isDirectory: true)
    }

    func createDirectories() throws {
        for d in [root, dataDir, thumbsDir, previewsDir, rendersDir, quickDir, logsDir, tmpDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    func original(_ p: Photo) -> URL { root.appendingPathComponent(p.relativePath) }
    func thumb(_ p: Photo) -> URL { thumbsDir.appendingPathComponent(p.id + ".jpg") }
    func preview(_ p: Photo) -> URL { previewsDir.appendingPathComponent(p.id + ".jpg") }
    func renderDir(_ p: Photo) -> URL { rendersDir.appendingPathComponent(p.id, isDirectory: true) }
    /// 16-bit master for one settings combination. The suffix changes whenever the engine request
    /// changes ("-v2": BMP header unwrapped; "-v3": SPP's ghost-colour / overexposure / processing-
    /// version cells, see EngineServer.quattroPokes; "-v4": the Quattro highlight-pixel readings fed
    /// to the engine; "-v5": the camera's own overexposure-correction and noise-reduction settings
    /// instead of a SIGMA Photo Pro set's. Earlier: 
    /// to the engine, no more lattice specks); superseded files age out of the LRU.
    func render(_ p: Photo, settings: SPPSettings, look: SPPColorAdjustment = SPPColorAdjustment()) -> URL {
        let r = p.engineRegion(for: settings)
        let region = r == p.defaultCrop ? "" : "_r\(r.x)-\(r.y)-\(r.width)-\(r.height)"
        let version = p.engine == .quattro ? "-v5" : "-v4"   // v5 changed Quattro requests only
        return renderDir(p).appendingPathComponent(settings.cacheKey + region + look.cacheSuffix + version + ".tif")
    }

    /// Folder for a capture date: `YYYY/YYYY-MM-DD`.
    func dayFolder(for date: Date) -> URL {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 0)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return root.appendingPathComponent(year, isDirectory: true).appendingPathComponent(day, isDirectory: true)
    }
}

extension SPPSettings {
    /// Stable, readable key for caches: `e+0.3_c0.0_s0.0_h-0.5_sa0.0_sh0.0_f0.0_wb1_cm3`.
    var cacheKey: String {
        let q = quantized()
        func f(_ v: Double) -> String { String(format: "%.1f", v == 0 ? 0 : v) }
        // the engine's output depends on the sliders, the colour adjustment and the developed region
        // (added by LibraryPaths.render); turns, flips, straightening and the crop are applied afterwards
        var k = "e\(f(q.exposure))_c\(f(q.contrast))_s\(f(q.shadow))_h\(f(q.highlight))_sa\(f(q.saturation))_sh\(f(q.sharpness))_f\(f(q.fillLight))_wb\(q.whiteBalance)_cm\(q.colorMode)"
        if let a = q.colorAdjustment { k += String(format: "_pc%+.1f%+.1f", a.x, a.y) }
        return k
    }
}
