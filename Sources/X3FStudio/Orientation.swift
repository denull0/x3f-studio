import Foundation
import CoreGraphics
import ImageIO

/// How a photo is turned and mirrored for display: the camera's own rotation, the user's extra
/// quarter turns, mirroring, and a small straightening angle. The engine always develops in sensor
/// orientation; everything here is applied by the app when an image is shown or exported.
struct FrameGeometry: Equatable {
    let sensor: CGSize       // the whole sensor frame
    let rotation: Int        // total clockwise rotation to the upright frame: camera + 90 × turns, 0/90/180/270
    var flipH = false        // mirrored left-right, after the rotation
    var flipV = false        // mirrored top-bottom, after the rotation

    init(sensor: CGSize, rotation: Int, flipH: Bool = false, flipV: Bool = false) {
        self.sensor = sensor; self.rotation = ((rotation % 360) + 360) % 360; self.flipH = flipH; self.flipV = flipV
    }

    /// The upright frame.
    var display: CGSize { rotation == 90 || rotation == 270 ? CGSize(width: sensor.height, height: sensor.width) : sensor }
    var displayRect: CGRect { CGRect(origin: .zero, size: display) }

    /// Sensor coordinates → upright frame coordinates (both y-down, pixels).
    var sensorToDisplay: CGAffineTransform {
        let W = sensor.width, H = sensor.height
        var t: CGAffineTransform
        switch rotation {
        case 90:  t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)   // (x, y) → (H − y, x)
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)  // (x, y) → (W − x, H − y)
        case 270: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)   // (x, y) → (y, W − x)
        default:  t = .identity
        }
        if flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: display.width, ty: 0)) }
        if flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: display.height)) }
        return t
    }

    func toDisplay(_ r: CGRect) -> CGRect { r.applying(sensorToDisplay).standardized }
    func toSensor(_ r: CGRect) -> CGRect { r.applying(sensorToDisplay.inverted()).standardized }
    func toDisplay(_ c: CropRect) -> CGRect { toDisplay(c.cgRect) }
    /// A display rectangle as an even-aligned sensor crop inside the frame.
    func cropRect(from r: CGRect, minSide: Int = 64) -> CropRect { CropRect(toSensor(r), in: sensor, minSide: minSide) }

    /// Rotation about the frame centre by `degrees` clockwise, in display coordinates.
    func straighten(_ degrees: Double) -> CGAffineTransform {
        let c = CGPoint(x: display.width / 2, y: display.height / 2)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(degrees) * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }

    /// The frame's outline after straightening (clockwise from the top-left corner).
    func straightenedFramePolygon(_ degrees: Double) -> [CGPoint] {
        let r = displayRect, t = straighten(degrees)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
    }

    /// The sensor region the engine must develop so that `crop` (display space, after straightening by
    /// `degrees`) is fully covered: the crop's corners turned back and boxed, clamped to the frame.
    func engineRegion(for crop: CGRect, straightenedBy degrees: Double) -> CropRect {
        var box = crop
        if abs(degrees) > 0.001 {
            let inv = straighten(degrees).inverted()
            let pts = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)].map { $0.applying(inv) }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -2, dy: -2)   // a little slack for resampling
        }
        return cropRect(from: box.intersection(displayRect))
    }
}

/// An image the engine produced for a sensor region, at some scale, in sensor orientation.
struct EngineImage {
    let image: CGImage
    let region: CropRect    // sensor pixels the image covers
    let scale: CGFloat      // image pixels per sensor pixel

    /// The region turned upright (with the user's turns, flips and straightening) and cut to `crop`
    /// (display space). `targetScale` nil keeps this image's scale.
    func composed(geometry g: FrameGeometry, straighten: Double, crop: CGRect, targetScale: CGFloat? = nil) -> CGImage? {
        let s = targetScale ?? scale
        let w = max(1, Int((crop.width * s).rounded())), h = max(1, Int((crop.height * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.11, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = abs(straighten) > 0.001 || s != scale ? .high : .default
        // work in y-down display pixels scaled by s
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: s, y: -s)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        if abs(straighten) > 0.001 { ctx.concatenate(g.straighten(straighten)) }
        ctx.concatenate(g.sensorToDisplay)
        ctx.translateBy(x: CGFloat(region.x), y: CGFloat(region.y))
        // CG draws images y-up: flip the region's box so row 0 lands at its top
        ctx.translateBy(x: 0, y: CGFloat(region.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(region.width), height: CGFloat(region.height)))
        return ctx.makeImage()
    }
}

extension CGRect {
    /// All four corners inside the polygon (convex, clockwise).
    func isInside(polygon: [CGPoint]) -> Bool {
        let pts = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
        return pts.allSatisfy { p in
            var inside = true
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                // clockwise polygon in y-down space: inside points lie to the right of each edge
                if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) < -0.5 { inside = false; break }
            }
            return inside
        }
    }

    /// The largest rectangle with this centre and aspect that fits inside the polygon (scaled down).
    func shrunk(toFit polygon: [CGPoint]) -> CGRect {
        if isInside(polygon: polygon) { return self }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let r = CGRect(x: midX - width * mid / 2, y: midY - height * mid / 2, width: width * mid, height: height * mid)
            if r.isInside(polygon: polygon) { lo = mid } else { hi = mid }
        }
        return CGRect(x: midX - width * lo / 2, y: midY - height * lo / 2, width: width * lo, height: height * lo)
    }
}
