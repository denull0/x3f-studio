import Foundation

/// A saved set of adjustments — the sliders, white balance, colour mode and temperature/tint — to
/// apply to other photos. The crop and the orientation are a photo's own and never part of one.
struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var adjustments: SPPSettings
    var created = Date()
    /// Sets only Temperature and Tint, leaving the photo's other adjustments alone (the built-in presets).
    var colorOnly: Bool? = nil

    /// Whether these settings are what this preset produces.
    func matches(_ s: SPPSettings) -> Bool {
        colorOnly == true ? (s.colorAdjustment ?? SPPColorAdjustment()) == (adjustments.colorAdjustment ?? SPPColorAdjustment()) : s.adjustments == adjustments
    }

    /// Takes the yellow-green cast off Merrill shots that the engine renders greener than the camera's
    /// own JPEG. Measured 9 Nov 2026 over 72 DP2 Merrill files: 17 come out greener than the camera
    /// JPEG by more than 0.05 stop (mean R/G and B/G in linear light), the five strongest by 0.15–0.36;
    /// the grid move that brings those five to the camera's balance has a median of B 6.5 · M 10, and
    /// the full match on the strongest (DP2M0666) is B 10 · M 10. B 5 · M 8 removes most of it while
    /// keeping some of SIGMA Photo Pro's warmth; the sliders show the values and stay adjustable.
    static let lessGreen: Preset = {
        var s = SPPSettings(); s.colorAdjustment = SPPColorAdjustment(x: -5, y: -8)
        return Preset(id: UUID(uuidString: "6C1E55A0-9E2B-4D7C-8C44-000000000001")!, name: "Less Green", adjustments: s, created: Date(timeIntervalSince1970: 0), colorOnly: true)
    }()
    /// Presets that come with the app: listed after the user's own, never deleted.
    static let builtIn: [Preset] = [lessGreen]
}

/// `presets.json` in the library's data folder.
struct PresetFile: Codable {
    var version = 1
    var presets: [Preset] = []
}

extension SPPSettings {
    /// The adjustments alone: these settings without crop, turns, flips or straightening, quantized.
    var adjustments: SPPSettings {
        var s = quantized()
        s.crop = nil; s.frameCrop = nil; s.turns = 0; s.flipH = false; s.flipV = false; s.straighten = 0
        return s
    }

    /// These settings with the adjustments of `other`, keeping this photo's crop and orientation.
    func applying(adjustmentsOf other: SPPSettings) -> SPPSettings {
        var s = other.adjustments
        s.crop = crop; s.frameCrop = frameCrop; s.turns = turns; s.flipH = flipH; s.flipV = flipV; s.straighten = straighten
        return s
    }

    /// These settings with `preset` applied: all its adjustments, or just its Temperature/Tint for a
    /// colour-only preset.
    func applying(_ preset: Preset) -> SPPSettings {
        guard preset.colorOnly == true else { return applying(adjustmentsOf: preset.adjustments) }
        var s = self
        s.colorAdjustment = preset.adjustments.colorAdjustment
        return s
    }

    /// A short name for a preset made of these settings: what differs from the camera's defaults.
    func presetSummary(base: SPPSettings) -> String {
        let a = adjustments
        var parts: [String] = []
        func slider(_ name: String, _ v: Double, _ unit: String = "") { if abs(v) >= 0.05 { parts.append(name + " " + String(format: "%+.1f", v) + unit) } }
        slider("Exposure", a.exposure, " EV"); slider("Contrast", a.contrast); slider("Shadows", a.shadow); slider("Highlights", a.highlight)
        slider("Saturation", a.saturation); slider("Sharpness", a.sharpness); slider("Fill", a.fillLight)
        if a.whiteBalance != base.whiteBalance { parts.append(WhiteBalance.name(for: a.whiteBalance)) }
        if a.colorMode != base.colorMode { parts.append(ColorMode.name(for: a.colorMode)) }
        if let c = a.colorAdjustment, !c.isNeutral { parts.append(c.readout) }
        return parts.isEmpty ? "As Shot" : parts.prefix(3).joined(separator: " · ")
    }
}
