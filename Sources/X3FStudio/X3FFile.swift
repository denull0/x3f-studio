import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers

/// Reads what the app needs from a Sigma X3F without the engine: the file's unique id,
/// the camera's recorded adjustment settings, the crop, the capture date and the camera's
/// own embedded JPEG (for instant thumbnails). Quattro files (X3F 4.x) keep their settings
/// in a TIFF-style IFD; Merrill files (X3F 3.0) in the header's extended-data table.
struct X3FFile {
    enum Failure: LocalizedError {
        case notX3F, unreadable
        var errorDescription: String? {
            switch self {
            case .notX3F: return "Not an X3F file"
            case .unreadable: return "Could not read the file"
            }
        }
    }

    let url: URL
    /// Content-derived id. (The header's own "unique identifier" is the same for every file from a camera.)
    let uniqueID: String
    let fileSize: Int
    let version: UInt32
    let rotation: Int
    let asShot: SPPSettings
    let cropRect: (left: Int, top: Int, right: Int, bottom: Int)?
    let captureDate: Date?
    let camera: CameraInfo
    let embeddedJPEGRange: Range<Int>?
    let embeddedSize: CGSize?
    /// EXIF orientation of the embedded JPEG (1 = none). When present, ImageIO's transform already
    /// turns the camera JPEG upright and the header rotation must not be applied again.
    let embeddedOrientation: Int

    init(url: URL) throws {
        self.url = url
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4 << 20), head.count >= 64 else { throw Failure.unreadable }
        guard head.prefix(4) == Data("FOVb".utf8) else { throw Failure.notX3F }

        func u16(_ o: Int) -> Int { o + 2 <= head.count ? Int(head[o]) | Int(head[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> UInt32 { o + 4 <= head.count ? UInt32(head[o]) | UInt32(head[o + 1]) << 8 | UInt32(head[o + 2]) << 16 | UInt32(head[o + 3]) << 24 : 0 }
        func srational(_ o: Int) -> Double {
            let n = Int32(bitPattern: u32(o)), d = Int32(bitPattern: u32(o + 4))
            return d != 0 ? Double(n) / Double(d) : 0
        }
        func f32(_ o: Int) -> Double { Double(Float(bitPattern: u32(o))) }
        func cstring(_ o: Int, _ n: Int) -> String {
            guard o + n <= head.count else { return "" }
            let bytes = head[o..<(o + n)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }

        version = u32(4)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? head.count
        fileSize = byteCount
        var hasher = SHA256()
        hasher.update(data: head.prefix(512 << 10))
        withUnsafeBytes(of: UInt64(byteCount).littleEndian) { hasher.update(bufferPointer: $0) }
        uniqueID = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()

        // Camera settings block: a TIFF-style IFD inside the v4 header (tags = SPP's TAG_V4HEAD_*).
        var settings = SPPSettings()
        var rot = 0
        var crop: (Int, Int, Int, Int)? = nil
        var cropVals = [Int](repeating: -1, count: 4)
        if version >> 16 >= 4 {
            rot = Int(u32(48))
            var n = Int(u32(52)); if n > 200 { n = 0 }
            for i in 0..<n {
                let e = 56 + i * 12
                guard e + 12 <= head.count else { break }
                let tag = u16(e), type = u16(e + 2), count = Int(u32(e + 4)), val = Int(u32(e + 8))
                func sr() -> Double? { (type == 10 && count == 1 && val + 8 <= head.count) ? srational(val) : nil }
                switch tag {
                case 1: settings.whiteBalance = val & 0xffff
                case 2: settings.colorMode = val & 0xffff
                case 3: if let v = sr() { settings.exposure = v }
                case 4: if let v = sr() { settings.contrast = v }
                case 5: if let v = sr() { settings.shadow = v }
                case 6: if let v = sr() { settings.highlight = v }
                case 7: if let v = sr() { settings.saturation = v }
                case 8: if let v = sr() { settings.sharpness = v }
                case 9: if let v = sr() { settings.fillLight = v }
                case 31...34: if type == 3 { cropVals[tag - 31] = val & 0xffff }
                default: break
                }
            }
            if cropVals.allSatisfy({ $0 >= 0 }), cropVals[2] > cropVals[0], cropVals[3] > cropVals[1] {
                crop = (cropVals[0], cropVals[1], cropVals[2], cropVals[3])
            }
        } else if version >> 16 == 3 {
            // Merrill (TRUE II) header: rotation, white balance and colour mode as text, then 64
            // typed floats holding the in-camera adjustments (and SPP's, when it saved the file).
            rot = Int(u32(36))
            settings.whiteBalance = X3FFile.whiteBalanceCode(cstring(40, 32))
            settings.colorMode = X3FFile.colorModeCode(cstring(72, 32))
            for i in 0..<64 where 104 + i < head.count && 168 + i * 4 + 4 <= head.count {
                let v = f32(168 + i * 4)
                switch Int(head[104 + i]) {
                case 1: settings.exposure = v
                case 2: settings.contrast = v
                case 3: settings.shadow = v
                case 4: settings.highlight = v
                case 5: settings.saturation = v
                case 6: settings.sharpness = v
                case 10: settings.fillLight = v
                default: break
                }
            }
        }
        if settings.whiteBalance == 0 { settings.whiteBalance = 1 }
        if settings.colorMode == 0 { settings.colorMode = 3 }
        asShot = settings.quantized()
        rotation = [0, 90, 180, 270].contains(rot) ? rot : 0
        cropRect = crop.map { (left: $0.0, top: $0.1, right: $0.2, bottom: $0.3) }

        // The camera's embedded JPEG: first JPEG SOI in the head of the file. Its EXIF carries the capture date.
        var jpegRange: Range<Int>? = nil
        var i = 24
        let bytes = [UInt8](head)
        while i < bytes.count - 3 {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                // make sure a decodable JPEG starts here (EXIF or JFIF marker right after SOI)
                if bytes[i + 3] == 0xE1 || bytes[i + 3] == 0xE0 || bytes[i + 3] == 0xDB || bytes[i + 3] == 0xC4 { jpegRange = i..<bytes.count; break }
            }
            i += 1
        }
        embeddedJPEGRange = jpegRange

        var date: Date? = nil
        var cam = CameraInfo()
        var size: CGSize? = nil
        var orient = 1
        if let r = jpegRange, let src = CGImageSourceCreateWithData(head.subdata(in: r) as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int { size = CGSize(width: w, height: h) }
            if let o = props[kCGImagePropertyOrientation] as? Int { orient = o }
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if let s = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String {
                date = X3FFile.parseEXIFDate(s)
            }
            if let m = tiff[kCGImagePropertyTIFFModel] as? String, !m.isEmpty { cam.model = m.hasPrefix("SIGMA") ? m : "SIGMA " + m }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { cam.iso = iso }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { cam.fNumber = f }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double { cam.exposureTime = t }
            if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { cam.focalLength = fl }
            if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { cam.focalLength35 = fl35 }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String { cam.lens = lens }
        }
        if date == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        }
        captureDate = date
        camera = cam
        embeddedSize = size
        embeddedOrientation = orient
    }

    /// Developed size after the camera's aspect crop, in sensor orientation.
    var developedSize: CGSize {
        if let c = cropRect { return CGSize(width: c.right - c.left, height: c.bottom - c.top) }
        if let s = embeddedSize { return s }
        return engineKind == .merrill ? CGSize(width: 4704, height: 3136) : CGSize(width: 5424, height: 3616)
    }

    /// The whole sensor frame in sensor orientation: the v4 header's column/row counts, else the
    /// developed size (Merrill files carry no crop, so the two are the same).
    var sensorSize: CGSize {
        if version >> 16 >= 4, let fh = try? FileHandle(forReadingFrom: url), let d = try? fh.read(upToCount: 48), d.count >= 48 {
            let w = Int(d[40]) | Int(d[41]) << 8 | Int(d[42]) << 16, h = Int(d[44]) | Int(d[45]) << 8 | Int(d[46]) << 16
            if w >= 1000, h >= 1000, w < 20000, h < 20000 { return CGSize(width: w, height: h) }
        }
        return developedSize
    }
    /// The camera's aspect-ratio crop as a `CropRect`, if the file records one.
    var cameraCrop: CropRect? { cropRect.map { CropRect(x: $0.left, y: $0.top, width: $0.right - $0.left, height: $0.bottom - $0.top) } }

    /// The engine that develops this file, from the header version.
    var engineKind: EngineKind { EngineKind.forVersion(version) }

    /// Engine kind from the first bytes of a file on disk (no full parse); nil if it is not an X3F.
    static func probeEngineKind(at url: URL) -> EngineKind? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 8), d.count == 8, d.prefix(4) == Data("FOVb".utf8) else { return nil }
        let v = UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24
        return EngineKind.forVersion(v)
    }

    /// SPP's white-balance preset codes for the names the Merrill cameras write into the header.
    static func whiteBalanceCode(_ name: String) -> Int {
        switch name {
        case "Auto": return 1
        case "Sunlight", "Daylight": return 2
        case "Shade": return 3
        case "Overcast": return 4
        case "Incandescent": return 5
        case "Fluorescent": return 6
        case "Flash": return 7
        case "Custom": return 8
        case "Monochrome": return 9
        case "AutoLSP": return 10
        case "ColorTemp": return 11
        default: return 1
        }
    }

    /// SPP's colour-mode codes for the header's colour-mode names.
    static func colorModeCode(_ name: String) -> Int {
        switch name.lowercased() {
        case "vivid": return 4
        case "neutral": return 5
        case "portrait": return 6
        case "landscape": return 7
        case "fov classic blue", "fovclassicblue", "fcblue": return 8
        default: return 3
        }
    }

    static func parseEXIFDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    /// The camera's own JPEG rendering, as a CGImage source, for thumbnails before the engine has run.
    func embeddedJPEGSource() -> CGImageSource? {
        guard let r = embeddedJPEGRange, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // the embedded JPEG is near the start; 16 MB is plenty for the camera's full-size preview
        guard let data = try? fh.read(upToCount: r.lowerBound + (16 << 20)), data.count > r.lowerBound else { return nil }
        return CGImageSourceCreateWithData(data.subdata(in: r.lowerBound..<data.count) as CFData, nil)
    }

    /// The camera's JPEG, upright, longest edge `maxPixel` (pass nil for full size).
    func embeddedThumbnail(maxPixel: Int?) -> CGImage? {
        guard let src = embeddedJPEGSource() else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let m = maxPixel { opts[kCGImageSourceThumbnailMaxPixelSize] = m }
        else if let s = embeddedSize { opts[kCGImageSourceThumbnailMaxPixelSize] = Int(max(s.width, s.height)) }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // ImageIO applied the JPEG's own orientation tag; only files without one need the header rotation
        return embeddedOrientation == 1 ? X3FFile.rotated(img, by: rotation) : img
    }

    /// Rotate a CGImage clockwise by 0/90/180/270 degrees.
    static func rotated(_ img: CGImage, by degrees: Int) -> CGImage? {
        guard degrees != 0 else { return img }
        let w = img.width, h = img.height
        let (ow, oh) = (degrees == 180) ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180)   // CG's y axis points up, so clockwise is negative
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}

extension CGImage {
    /// Write as JPEG with optional metadata.
    @discardableResult
    func writeJPEG(to url: URL, quality: Double, properties: [CFString: Any] = [:]) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, self, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
