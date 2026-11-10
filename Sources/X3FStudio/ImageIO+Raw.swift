import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum RawImage {
    /// Packed 8-bit RGB from the engine's quick path → CGImage, rotated upright.
    static func cgImage(rgb8 url: URL, width: Int, height: Int, rotation: Int) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= width * height * 3,
              let provider = CGDataProvider(data: data.prefix(width * height * 3) as CFData) else { return nil }
        guard let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        // Draw into a native 32-bit context once so later display is cheap, applying the rotation.
        return X3FFile.rotated(img, by: rotation) ?? img
    }

    /// Full-size TIFF from the engine's save path → CGImage, upright (or in sensor orientation with
    /// `applyOrientation: false`, for `EngineImage.composed`).
    static func cgImage(tiff url: URL, maxPixel: Int? = nil, applyOrientation: Bool = true) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let m = maxPixel { opts[kCGImageSourceThumbnailMaxPixelSize] = m }
        else if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func cgImage(file url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func downscaled(_ img: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(img.width, img.height)))
        if scale >= 1 { return img }
        let w = Int(CGFloat(img.width) * scale), h = Int(CGFloat(img.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

enum JPEGExport {
    /// Metadata for an exported JPEG: the camera's EXIF/TIFF tags (from the X3F's embedded JPEG), upright.
    static func metadata(for photo: Photo, original: URL) -> [CFString: Any] {
        var exif: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        if let x = try? X3FFile(url: original), let src = x.embeddedJPEGSource(),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exif[kCGImagePropertyExifDateTimeOriginal] = df.string(from: photo.captureDate)
        exif[kCGImagePropertyExifDateTimeDigitized] = exif[kCGImagePropertyExifDateTimeDigitized] ?? df.string(from: photo.captureDate)
        exif[kCGImagePropertyExifColorSpace] = 1
        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension); exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
        tiff[kCGImagePropertyTIFFMake] = tiff[kCGImagePropertyTIFFMake] ?? "SIGMA"
        tiff[kCGImagePropertyTIFFModel] = tiff[kCGImagePropertyTIFFModel] ?? photo.camera.model
        tiff[kCGImagePropertyTIFFSoftware] = "X3F Studio (SIGMA Photo Pro engine)"
        tiff[kCGImagePropertyTIFFDateTime] = df.string(from: photo.captureDate)
        tiff[kCGImagePropertyTIFFOrientation] = 1
        return [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyOrientation: 1,
        ]
    }

    /// Full-size JPEG from the engine's 16-bit TIFF master (upright, no crop/orientation edits applied).
    static func write(tiff: URL, to jpeg: URL, photo: Photo, original: URL, quality: Double = 0.92, maxPixel: Int? = nil) throws {
        guard let img = RawImage.cgImage(tiff: tiff, maxPixel: maxPixel) else { throw NSError(domain: "X3FStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read the rendered image"]) }
        try write(image: img, to: jpeg, photo: photo, original: original, quality: quality)
    }

    /// JPEG from a finished image (see `RenderService.finalImage`), with the camera's metadata.
    static func write(image img: CGImage, to jpeg: URL, photo: Photo, original: URL, quality: Double = 0.92) throws {
        var props = metadata(for: photo, original: original)
        props[kCGImagePropertyDPIWidth] = 300; props[kCGImagePropertyDPIHeight] = 300
        guard img.writeJPEG(to: jpeg, quality: quality, properties: props) else { throw NSError(domain: "X3FStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write \(jpeg.lastPathComponent)"]) }
    }
}
