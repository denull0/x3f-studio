// Draws the app icon: "X3FStudio" on one line — "X3F" in Sigma Serif, "Studio" in Sigma Sans, cap
// heights matched — black on a white rounded square (macOS icon grid). The fonts are Sigma's own web
// fonts from sigma-global.com and are not distributed with the app; only this rasterised icon is.
// usage: makeicon out.png SigmaSerif-Headline.ttf SigmaSans-Medium.ttf   (1024x1024)
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let args = CommandLine.arguments
guard args.count >= 4 else { fputs("usage: makeicon out.png serif.ttf sans.ttf\n", stderr); exit(2) }
let out = URL(fileURLWithPath: args[1])

func descriptor(_ path: String) -> CTFontDescriptor {
    guard let d = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor], let first = d.first else {
        fputs("cannot read font \(path)\n", stderr); exit(1)
    }
    return first
}
let serif = descriptor(args[2]), sans = descriptor(args[3])

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: the squircle occupies ~82% of the canvas
let inset = size * 0.09
let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let plateRadius = plate.width * 0.225
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.22))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.06)); ctx.setLineWidth(2)
ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 1, dy: 1), cornerWidth: plateRadius - 1, cornerHeight: plateRadius - 1, transform: nil)); ctx.strokePath()

/// "X3F" + "Studio" as one line at a serif point size `pt`; the sans run is scaled so both cap heights match.
func line(_ pt: CGFloat) -> (CTLine, CGRect) {
    let serifFont = CTFontCreateWithFontDescriptor(serif, pt, nil)
    let probe = CTFontCreateWithFontDescriptor(sans, pt, nil)
    let sansPt = pt * CTFontGetCapHeight(serifFont) / max(1, CTFontGetCapHeight(probe))
    let sansFont = CTFontCreateWithFontDescriptor(sans, sansPt, nil)
    let black = CGColor(gray: 0, alpha: 1)
    let s = NSMutableAttributedString()
    s.append(NSAttributedString(string: "X3F", attributes: [.init(kCTFontAttributeName as String): serifFont, .init(kCTForegroundColorAttributeName as String): black]))
    s.append(NSAttributedString(string: "Studio", attributes: [.init(kCTFontAttributeName as String): sansFont, .init(kCTForegroundColorAttributeName as String): black,
                                                               .init(kCTKernAttributeName as String): sansPt * 0.01]))
    let l = CTLineCreateWithAttributedString(s)
    return (l, CTLineGetBoundsWithOptions(l, [.useGlyphPathBounds]))
}
var (l, bounds) = line(300)
let pt = 300 * (plate.width * 0.80) / bounds.width
(l, bounds) = line(pt)
ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true); ctx.setAllowsAntialiasing(true)
ctx.textPosition = CGPoint(x: plate.midX - bounds.midX, y: plate.midY - bounds.midY)
CTLineDraw(l, ctx)

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) at \(Int(pt)) pt")
