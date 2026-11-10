import Foundation

/// SIGMA Photo Pro's X3F adjustment set, in SPP's own units.
/// These are passed straight to the engine; nothing is post-processed in the app.
struct SPPSettings: Codable, Equatable, Hashable {
    var exposure: Double = 0      // EV, -3.0 … +3.0
    var contrast: Double = 0      // -2.0 … +2.0
    var shadow: Double = 0
    var highlight: Double = 0
    var saturation: Double = 0
    var sharpness: Double = 0
    var fillLight: Double = 0
    var whiteBalance: Int = 1     // SPP preset code, see `WhiteBalance`
    var colorMode: Int = 3        // SPP colour mode code, see `ColorMode`
    /// SPP's Color Adjustment grid position for this photo; nil = the app-wide default
    /// (the user's SIGMA Photo Pro set, see `SPPColorAdjustment`).
    var colorAdjustment: SPPColorAdjustment? = nil
    /// Legacy: a crop in sensor pixels from the first crop tool; converted to `frameCrop` when the library opens.
    var crop: CropRect? = nil
    /// The crop in the upright frame (after `turns`, flips and straightening), in frame pixels;
    /// nil = the camera's own framing.
    var frameCrop: CropRect? = nil
    /// Extra quarter turns clockwise (0–3), mirroring, and a straightening angle in degrees (clockwise).
    var turns: Int = 0
    var flipH: Bool = false
    var flipV: Bool = false
    var straighten: Double = 0

    /// Round to the engine's 0.1 steps (and the colour grid's 0.5) so equal-looking settings compare equal.
    func quantized() -> SPPSettings {
        func q(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var s = self
        s.exposure = q(exposure); s.contrast = q(contrast); s.shadow = q(shadow); s.highlight = q(highlight)
        s.saturation = q(saturation); s.sharpness = q(sharpness); s.fillLight = q(fillLight)
        if let c = colorAdjustment { s.colorAdjustment = SPPColorAdjustment(x: (c.x * 2).rounded() / 2, y: (c.y * 2).rounded() / 2) }
        s.turns = ((turns % 4) + 4) % 4
        s.straighten = min(45, max(-45, q(straighten)))
        return s
    }
    var isOriented: Bool { turns != 0 || flipH || flipV || abs(straighten) > 0.001 }

    init() {}

    /// Every field is optional on disk, so catalogs written before a field existed still load
    /// (a synthesized decoder would reject them and the library would come up empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        highlight = try c.decodeIfPresent(Double.self, forKey: .highlight) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        fillLight = try c.decodeIfPresent(Double.self, forKey: .fillLight) ?? 0
        whiteBalance = try c.decodeIfPresent(Int.self, forKey: .whiteBalance) ?? 1
        colorMode = try c.decodeIfPresent(Int.self, forKey: .colorMode) ?? 3
        colorAdjustment = try c.decodeIfPresent(SPPColorAdjustment.self, forKey: .colorAdjustment)
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        frameCrop = try c.decodeIfPresent(CropRect.self, forKey: .frameCrop)
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
    }
}

enum WhiteBalance: Int, CaseIterable, Identifiable {
    case auto = 1, sunlight = 2, shade = 3, overcast = 4, incandescent = 5, fluorescent = 6, flash = 7, custom = 8, autoLSP = 10
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .auto: return "Auto"
        case .sunlight: return "Sunlight"
        case .shade: return "Shade"
        case .overcast: return "Overcast"
        case .incandescent: return "Incandescent"
        case .fluorescent: return "Fluorescent"
        case .flash: return "Flash"
        case .custom: return "Custom (camera)"
        case .autoLSP: return "Auto (light source priority)"
        }
    }
    static func name(for code: Int) -> String { WhiteBalance(rawValue: code)?.name ?? "Preset \(code)" }
}

enum ColorMode: Int, CaseIterable, Identifiable {
    case standard = 3, vivid = 4, neutral = 5, portrait = 6, landscape = 7, fovClassicBlue = 8
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .standard: return "Standard"
        case .vivid: return "Vivid"
        case .neutral: return "Neutral"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        case .fovClassicBlue: return "FOV Classic Blue"
        }
    }
    static func name(for code: Int) -> String { ColorMode(rawValue: code)?.name ?? "Mode \(code)" }
}

struct CameraInfo: Codable, Equatable, Hashable {
    var model: String = "SIGMA dp Quattro"
    var iso: Int = 0
    var fNumber: Double = 0
    var exposureTime: Double = 0    // seconds
    var focalLength: Double = 0     // mm
    var focalLength35: Int = 0
    var lens: String = ""

    var summary: String {
        var parts: [String] = []
        if fNumber > 0 { parts.append(String(format: "ƒ/%.1f", fNumber)) }
        if exposureTime > 0 { parts.append(exposureTime >= 1 ? String(format: "%.0fs", exposureTime) : "1/\(Int((1 / exposureTime).rounded()))s") }
        if iso > 0 { parts.append("ISO \(iso)") }
        if focalLength > 0 { parts.append(String(format: "%.0fmm", focalLength)) }
        return parts.joined(separator: "  ")
    }
}

/// Which SIGMA Photo Pro engine develops a file; decided from the X3F header version on import.
enum EngineKind: String, Codable {
    case quattro      // X3F 4.x: dp Quattro (lib95_QuattroDLLForMac)
    case merrill      // X3F 3.0: DP1/DP2/DP3 Merrill, SD1 (lib99_MerillDLLForMac)
    case unsupported  // X3F 2.x (SD9/SD10/SD14/SD15, DP1/DP2) and anything else: camera JPEG only

    var isSupported: Bool { self != .unsupported }
    var name: String {
        switch self {
        case .quattro: return "Quattro"
        case .merrill: return "Merrill"
        case .unsupported: return "not supported"
        }
    }
    /// From the X3F header's version word (major in the high 16 bits).
    static func forVersion(_ version: UInt32) -> EngineKind {
        switch version >> 16 {
        case 4: return .quattro
        case 3: return .merrill
        default: return .unsupported
        }
    }
}

struct Photo: Identifiable, Codable, Equatable, Hashable {
    let id: String                  // the X3F's 16-byte unique identifier, hex
    var relativePath: String        // e.g. "2026/2026-11-07/SDIM0457.X3F", relative to the library root
    var fileName: String
    var captureDate: Date
    var importedAt: Date
    var pixelWidth: Int             // developed size after the camera's aspect-ratio crop
    var pixelHeight: Int
    var rotation: Int               // 0, 90, 180, 270 (clockwise, as the camera recorded it)
    var camera: CameraInfo
    var asShot: SPPSettings         // the settings the camera recorded in the file
    var edited: SPPSettings?        // the user's settings; nil means "as shot"
    var engine: EngineKind = .quattro   // which engine develops it; unsupported files show and export the camera JPEG
    var fileSize: Int = 0
    /// The whole sensor frame in sensor orientation (0 until read from the file), and the camera's
    /// own aspect-ratio crop inside it, if the file records one. Cropping works within the frame.
    var sensorWidth: Int = 0
    var sensorHeight: Int = 0
    var cameraCrop: CropRect? = nil
    /// Marked by the user (P); the library can show flagged photos only.
    var flagged: Bool = false
    /// 0 (none) to 5 stars (the 0–5 keys).
    var rating: Int = 0
    /// Keywords, matched case-insensitively and kept as first typed.
    var tags: [String] = []
    /// The render (settings, region, colour adjustment, engine version) the thumbnail and preview were
    /// made from, as the master's file name; nil until the engine has developed them once.
    var previewKey: String? = nil
    /// When a JPEG was last exported or shared, and with which settings.
    var exportedAt: Date? = nil
    var exportedSettings: SPPSettings? = nil
    /// The Blank post this photo was last published in.
    var blankPost: BlankPostRef? = nil
    /// What the local model made of the picture (see `TaggingService`).
    var aiCaption: String? = nil
    var aiCategories: [String] = []
    var aiTags: [String] = []
    var aiMood: String? = nil
    var aiModel: String? = nil
    var aiAt: Date? = nil
    /// What the local model thinks the picture needs (a suggestion; applied only on request).
    var aiAdvice: PhotoAdvice? = nil

    init(id: String, relativePath: String, fileName: String, captureDate: Date, importedAt: Date, pixelWidth: Int, pixelHeight: Int,
         rotation: Int, camera: CameraInfo, asShot: SPPSettings, edited: SPPSettings?, engine: EngineKind, fileSize: Int,
         sensorWidth: Int = 0, sensorHeight: Int = 0, cameraCrop: CropRect? = nil) {
        self.id = id; self.relativePath = relativePath; self.fileName = fileName; self.captureDate = captureDate; self.importedAt = importedAt
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.rotation = rotation; self.camera = camera
        self.asShot = asShot; self.edited = edited; self.engine = engine; self.fileSize = fileSize
        self.sensorWidth = sensorWidth; self.sensorHeight = sensorHeight; self.cameraCrop = cameraCrop
    }

    enum CodingKeys: String, CodingKey { case id, relativePath, fileName, captureDate, importedAt, pixelWidth, pixelHeight, rotation, camera, asShot, edited, engine, isQuattro, fileSize, sensorWidth, sensorHeight, cameraCrop, flagged, rating, tags, previewKey, exportedAt, exportedSettings, blankPost, aiCaption, aiCategories, aiTags, aiMood, aiModel, aiAt, aiAdvice }

    /// Secondary identity used to catch re-imports of a file already in the library.
    var duplicateKey: String { "\(fileName.lowercased())|\(fileSize)|\(Int(captureDate.timeIntervalSince1970))" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? (relativePath as NSString).lastPathComponent
        captureDate = try c.decode(Date.self, forKey: .captureDate)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? captureDate
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 4816
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 3616
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        camera = try c.decodeIfPresent(CameraInfo.self, forKey: .camera) ?? CameraInfo()
        asShot = try c.decodeIfPresent(SPPSettings.self, forKey: .asShot) ?? SPPSettings()
        edited = try c.decodeIfPresent(SPPSettings.self, forKey: .edited)
        if edited?.colorAdjustment?.isNeutral == true { edited?.colorAdjustment = nil }   // a reset Temperature/Tint is no adjustment
        if let e = try c.decodeIfPresent(EngineKind.self, forKey: .engine) { engine = e }
        else {
            // catalogs written before the Merrill engine only knew "Quattro or not"; the library re-probes the rest from the file
            engine = (try c.decodeIfPresent(Bool.self, forKey: .isQuattro) ?? true) ? .quattro : .unsupported
        }
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        sensorWidth = try c.decodeIfPresent(Int.self, forKey: .sensorWidth) ?? 0
        sensorHeight = try c.decodeIfPresent(Int.self, forKey: .sensorHeight) ?? 0
        cameraCrop = try c.decodeIfPresent(CropRect.self, forKey: .cameraCrop)
        flagged = try c.decodeIfPresent(Bool.self, forKey: .flagged) ?? false
        rating = min(5, max(0, try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0))
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        previewKey = try c.decodeIfPresent(String.self, forKey: .previewKey)
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt)
        exportedSettings = try c.decodeIfPresent(SPPSettings.self, forKey: .exportedSettings)
        blankPost = try c.decodeIfPresent(BlankPostRef.self, forKey: .blankPost)
        aiCaption = try c.decodeIfPresent(String.self, forKey: .aiCaption)
        aiCategories = try c.decodeIfPresent([String].self, forKey: .aiCategories) ?? []
        aiTags = try c.decodeIfPresent([String].self, forKey: .aiTags) ?? []
        aiMood = try c.decodeIfPresent(String.self, forKey: .aiMood)
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel)
        aiAt = try c.decodeIfPresent(Date.self, forKey: .aiAt)
        aiAdvice = try c.decodeIfPresent(PhotoAdvice.self, forKey: .aiAdvice)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(relativePath, forKey: .relativePath); try c.encode(fileName, forKey: .fileName)
        try c.encode(captureDate, forKey: .captureDate); try c.encode(importedAt, forKey: .importedAt)
        try c.encode(pixelWidth, forKey: .pixelWidth); try c.encode(pixelHeight, forKey: .pixelHeight); try c.encode(rotation, forKey: .rotation)
        try c.encode(camera, forKey: .camera); try c.encode(asShot, forKey: .asShot); try c.encodeIfPresent(edited, forKey: .edited)
        try c.encode(engine, forKey: .engine); try c.encode(engine == .quattro, forKey: .isQuattro); try c.encode(fileSize, forKey: .fileSize)
        try c.encode(sensorWidth, forKey: .sensorWidth); try c.encode(sensorHeight, forKey: .sensorHeight); try c.encodeIfPresent(cameraCrop, forKey: .cameraCrop)
        if flagged { try c.encode(true, forKey: .flagged) }
        if rating > 0 { try c.encode(rating, forKey: .rating) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(previewKey, forKey: .previewKey)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt); try c.encodeIfPresent(exportedSettings, forKey: .exportedSettings)
        try c.encodeIfPresent(blankPost, forKey: .blankPost)
        try c.encodeIfPresent(aiCaption, forKey: .aiCaption)
        if !aiCategories.isEmpty { try c.encode(aiCategories, forKey: .aiCategories) }
        if !aiTags.isEmpty { try c.encode(aiTags, forKey: .aiTags) }
        try c.encodeIfPresent(aiMood, forKey: .aiMood); try c.encodeIfPresent(aiModel, forKey: .aiModel); try c.encodeIfPresent(aiAt, forKey: .aiAt)
        try c.encodeIfPresent(aiAdvice, forKey: .aiAdvice)
    }

    var settings: SPPSettings { edited ?? asShot }
    var isEdited: Bool { edited != nil && edited != asShot }
    /// The sliders, white balance, colour mode or temperature/tint differ from the camera's (badge).
    var hasAdjustments: Bool { guard let e = edited else { return false }; return e.adjustments != asShot.adjustments }
    /// The last export was made from the current settings.
    var isExportCurrent: Bool { exportedSettings == settings.quantized() }

    /// The user's tags and the model's, matched case-insensitively.
    func hasTag(_ tag: String) -> Bool { (tags + aiTags).contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    /// Text the search field matches: file name, tags, caption, categories, mood.
    var searchText: String {
        (([fileName, aiCaption ?? "", aiMood ?? ""] + tags + aiTags + aiCategories).joined(separator: " ") + (aiAdvice?.needsWork == true ? " needs attention suggested" : "")).lowercased()
    }
    /// "street, autumn; family" → ["street", "autumn", "family"].
    static func parseTags(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == ";" || $0 == "\n" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The whole sensor frame, in sensor orientation (falls back to the developed size until the file was read).
    var sensorSize: CGSize { sensorWidth > 0 && sensorHeight > 0 ? CGSize(width: sensorWidth, height: sensorHeight) : CGSize(width: pixelWidth, height: pixelHeight) }
    var fullFrame: CropRect { CropRect(x: 0, y: 0, width: Int(sensorSize.width), height: Int(sensorSize.height)) }
    /// The camera's own framing (sensor pixels), else the whole frame.
    var defaultCrop: CropRect { cameraCrop ?? fullFrame }

    /// Upright-frame geometry for some settings: the camera's rotation plus the user's turns and flips.
    func geometry(for s: SPPSettings) -> FrameGeometry { FrameGeometry(sensor: sensorSize, rotation: rotation + 90 * s.turns, flipH: s.flipH, flipV: s.flipV) }
    var geometry: FrameGeometry { geometry(for: settings) }
    /// The camera's framing in the upright frame of `s`.
    func defaultFrameCrop(for s: SPPSettings) -> CGRect { geometry(for: s).toDisplay(defaultCrop) }
    /// What is shown and exported, in the upright frame: the user's crop, else the camera's framing,
    /// shrunk to stay inside the frame once it is straightened.
    func frameCrop(for s: SPPSettings) -> CGRect {
        let g = geometry(for: s)
        var c = s.frameCrop?.cgRect ?? g.toDisplay(defaultCrop)
        if abs(s.straighten) > 0.001 { c = c.shrunk(toFit: g.straightenedFramePolygon(s.straighten)) }
        return c
    }
    /// The sensor region the engine develops for `s` (covers the crop after straightening).
    func engineRegion(for s: SPPSettings) -> CropRect { geometry(for: s).engineRegion(for: frameCrop(for: s), straightenedBy: s.straighten) }
    var hasCustomCrop: Bool { settings.frameCrop != nil || settings.isOriented }

    /// Developed size as displayed (after crop, turns, flips and straightening).
    var displaySize: CGSize { let c = frameCrop(for: settings); return CGSize(width: c.width.rounded(), height: c.height.rounded()) }
    /// The whole frame as displayed (what the crop tool shows).
    var frameDisplaySize: CGSize { geometry.display }
    var aspectRatio: CGFloat { let s = displaySize; return s.height > 0 ? s.width / s.height : 1.5 }
}

/// The local model's review of a photo as currently developed: what to change, as additions to the
/// current settings. Only a suggestion until the user applies it.
struct PhotoAdvice: Codable, Equatable, Hashable {
    var needsWork: Bool
    var exposure: Double = 0      // EV to add
    var temperature: Double = 0   // colour grid units to add: blue −, amber +
    var tint: Double = 0          // magenta −, green +
    var straighten: Double = 0    // degrees to turn the picture, clockwise +
    var framing: String? = nil    // a cropping hint, if any
    var note: String
    var model: String
    var at: Date

    /// Nothing concrete to apply (the note may still say something).
    var isEmpty: Bool { abs(exposure) < 0.05 && abs(temperature) < 0.25 && abs(tint) < 0.25 && abs(straighten) < 0.05 && (framing ?? "").isEmpty }
    /// Short labels for the proposed changes.
    var changes: [String] {
        var out: [String] = []
        if abs(exposure) >= 0.05 { out.append(String(format: "%+.1f EV", exposure)) }
        if abs(temperature) >= 0.25 { out.append((temperature > 0 ? "warmer " : "cooler ") + SPPColorAdjustment.temperatureReadout(temperature)) }
        if abs(tint) >= 0.25 { out.append((tint > 0 ? "greener " : "more magenta ") + SPPColorAdjustment.tintReadout(tint)) }
        if abs(straighten) >= 0.05 { out.append(String(format: "straighten %+.1f°", straighten)) }
        if let f = framing, !f.isEmpty { out.append(f) }
        return out
    }
}

/// What the local model made of one day's photos (keyed by `Library.dayKey`).
struct SessionInfo: Codable, Equatable, Hashable {
    var title: String
    var summary: String
    var categories: [String]
    var model: String
    var at: Date
    var photoCount: Int
}

struct Catalog: Codable {
    var version: Int = 1
    var photos: [Photo] = []
    var sessions: [String: SessionInfo] = [:]

    init(version: Int = 1, photos: [Photo] = [], sessions: [String: SessionInfo] = [:]) { self.version = version; self.photos = photos; self.sessions = sessions }

    enum CodingKeys: String, CodingKey { case version, photos, sessions }
    /// Every field optional on disk, so catalogs from before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        photos = try c.decodeIfPresent([Photo].self, forKey: .photos) ?? []
        sessions = try c.decodeIfPresent([String: SessionInfo].self, forKey: .sessions) ?? [:]
    }
}
