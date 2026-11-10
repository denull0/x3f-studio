import Foundation

/// A position on SIGMA Photo Pro's Color Adjustment grid (blue–amber across, magenta–green down, in
/// half-unit steps): the editor's Temperature and Tint sliders, per photo. Neutral (0, 0) leaves the
/// camera's colour as the engine develops it; nothing is applied by default.
///
/// Measured on SPP 6.9 with the recording shim (tools/sppcap, 9 Nov 2026, six grid positions,
/// exact to ±2 of 32768): the grid position becomes three 16-bit gains in parameter cells
/// 228/230/232 (32768 = ×1). Per unit along the blue→amber axis the raw R/G/B densities are
/// (0, 0.03, 0.06) stops, per unit along the magenta→green axis (0.03, 0, 0.03); the three are
/// shifted so the smallest is 0 and turned into gains with 2^-d.
struct SPPColorAdjustment: Equatable, Hashable, Codable {
    /// Blue (negative) … amber (positive), SPP grid units.
    var x: Double = 0
    /// Magenta (negative) … green (positive), SPP grid units.
    var y: Double = 0

    var isNeutral: Bool { abs(x) < 0.05 && abs(y) < 0.05 }

    /// Gains for parameter cells 228 (R), 230 (G), 232 (B).
    var engineGains: [UInt16] {
        let raw = [y * 0.03, x * 0.03, x * 0.06 + y * 0.03]
        let floor = raw.min() ?? 0
        return raw.map { UInt16(min(32768, max(0, (32768 * pow(2, -($0 - floor))).rounded()))) }
    }
    /// `set=` pokes for the engine server.
    var pokes: String { let g = engineGains; return "228:u16:\(g[0]);230:u16:\(g[1]);232:u16:\(g[2])" }
    /// Part of the render cache file name, so masters made with another adjustment aren't reused.
    var cacheSuffix: String { isNeutral ? "" : String(format: "-ca%+.1f%+.1f", x, y) }
    /// SPP's own readout, e.g. "B 3.5 · M 4.5".
    var readout: String { "\(SPPColorAdjustment.temperatureReadout(x)) · \(SPPColorAdjustment.tintReadout(y))" }
    /// The grid's horizontal readout: blue ("B 3.5") or amber ("A 2.0"), "0" at the centre.
    static func temperatureReadout(_ x: Double) -> String { abs(x) < 0.05 ? "0" : x < 0 ? String(format: "B %.1f", -x) : String(format: "A %.1f", x) }
    /// The grid's vertical readout: magenta ("M 4.5") or green ("G 1.0").
    static func tintReadout(_ y: Double) -> String { abs(y) < 0.05 ? "0" : y < 0 ? String(format: "M %.1f", -y) : String(format: "G %.1f", y) }
    /// How far SPP's grid goes on each side of the centre.
    static let range: ClosedRange<Double> = -40...40

}
