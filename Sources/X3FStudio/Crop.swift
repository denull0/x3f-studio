import Foundation
import CoreGraphics

/// A crop in sensor pixels (the engine's frame before the display rotation). The engine develops
/// exactly this rectangle (`trim=`), so thumbnails, masters and exports all carry it.
struct CropRect: Codable, Equatable, Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var size: CGSize { CGSize(width: width, height: height) }
    /// The engine server's `trim=l,t,r,b` field (right and bottom inclusive).
    var trimField: String { "\(x),\(y),\(x + width - 1),\(y + height - 1)" }

    init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }

    /// From a continuous rectangle: kept inside `frame`, at least `minSide` wide and high, and on even
    /// coordinates (the Quattro top layer is sampled 2:1 against the colour layers).
    init(_ r: CGRect, in frame: CGSize, minSide: Int = 64) {
        func even(_ v: CGFloat) -> Int { Int((v / 2).rounded()) * 2 }
        let fw = Int(frame.width), fh = Int(frame.height)
        var w = max(minSide, min(fw, even(r.width))), h = max(minSide, min(fh, even(r.height)))
        let x = max(0, min(fw - w, even(r.minX))), y = max(0, min(fh - h, even(r.minY)))
        if x + w > fw { w = fw - x }
        if y + h > fh { h = fh - y }
        self.init(x: x, y: y, width: w, height: h)
    }
}

/// The crop tool's aspect-ratio choices, as in Photos.
enum CropAspect: String, CaseIterable, Identifiable {
    case freeform, original, square, r3x2, r4x3, r16x9, r5x4, r7x5
    var id: String { rawValue }

    var name: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .r3x2: return "3 : 2"
        case .r4x3: return "4 : 3"
        case .r16x9: return "16 : 9"
        case .r5x4: return "5 : 4"
        case .r7x5: return "7 : 5"
        }
    }

    /// Width over height in landscape form; nil for freeform. `original` is the camera's own framing.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .freeform: return nil
        case .original: return original.height > 0 ? max(original.width, original.height) / min(original.width, original.height) : nil
        case .square: return 1
        case .r3x2: return 3 / 2
        case .r4x3: return 4 / 3
        case .r16x9: return 16 / 9
        case .r5x4: return 5 / 4
        case .r7x5: return 7 / 5
        }
    }
}

extension CGRect {
    /// The largest rectangle of aspect `ratio` (width / height) centred in `self`.
    func largestInscribed(ratio: CGFloat) -> CGRect {
        guard ratio > 0, width > 0, height > 0 else { return self }
        var w = width, h = width / ratio
        if h > height { h = height; w = height * ratio }
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// Moved (not resized) so it lies within `bounds`.
    func confined(to bounds: CGRect) -> CGRect {
        var r = self
        if r.width > bounds.width { r.size.width = bounds.width }
        if r.height > bounds.height { r.size.height = bounds.height }
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
