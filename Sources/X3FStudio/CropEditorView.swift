import SwiftUI
import AppKit

/// Photos-style crop tool for the editor: the whole frame — turned, flipped and straightened as the
/// settings say — fitted to the area, a draggable crop rectangle with corner and edge handles, a
/// rule-of-thirds grid, aspect presets, rotate / flip buttons, a straighten slider, Reset and Done.
/// Works in the upright frame's pixels; the crop is stored in `SPPSettings.frameCrop`.
struct CropEditorArea: View {
    let frame: EngineImage?             // the whole frame in sensor orientation (a quick render)
    let photo: Photo
    @Binding var settings: SPPSettings
    var onDone: () -> Void

    @State private var rect: CGRect = .zero          // the crop in frame pixels while editing
    @State private var aspect: CropAspect = .freeform
    @State private var portrait = false
    @State private var dragStart: CGRect?
    @State private var shown: (key: String, image: CGImage)?
    /// Dragging outside the rectangle turns the picture about the rectangle's centre (as in Photoshop
    /// and Lightroom); on screen the rectangle stays under the pivot and slides home on release.
    @State private var rotation: RotationDrag?
    @State private var pan: CGSize = .zero
    @State private var levelling = false   // the straighten slider is being dragged
    private var fineGrid: Bool { rotation != nil || levelling }

    struct RotationDrag {
        let pivot: CGPoint        // the rectangle's centre on screen when the drag began
        let startAngle: Double    // the pointer's angle about the pivot at the start, degrees
        let straighten0: Double
        let rect0: CGRect
        var pointer: CGPoint
    }

    private var geometry: FrameGeometry { photo.geometry(for: settings) }
    private var frameRect: CGRect { geometry.displayRect }
    private var polygon: [CGPoint] { geometry.straightenedFramePolygon(settings.straighten) }
    private var minSide: CGFloat { 64 }

    /// Locked width/height in the current orientation, if any.
    private var lockedRatio: CGFloat? {
        guard let r = aspect.ratio(original: photo.defaultFrameCrop(for: settings).size) else { return nil }
        return portrait ? 1 / r : r
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // a band around the frame, so there is always room outside the rectangle to turn the picture
                let inset: CGFloat = 36
                let fit = CropEditorArea.fitRect(geometry.display, in: CGSize(width: max(1, geo.size.width - 2 * inset), height: max(1, geo.size.height - 2 * inset))).offsetBy(dx: inset, dy: inset)
                let scale = fit.width / max(1, geometry.display.width)
                let key = "\(settings.turns)|\(settings.flipH)|\(settings.flipV)|\(settings.straighten)|\(Int(fit.width))|\(frame.map { ObjectIdentifier($0.image).hashValue } ?? 0)"
                ZStack(alignment: .topLeading) {
                    Color(white: 0.11)
                    // everywhere outside the rectangle and its handles: drag to turn the picture
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(rotateDrag(fit: fit, scale: scale))
                        .onContinuousHover { phase in
                            switch phase {
                            case .active: CropCursor.rotate.set()
                            case .ended: NSCursor.arrow.set()
                            }
                        }
                    Group {
                        if let img = shown?.image {
                            Image(decorative: img, scale: 1).resizable().interpolation(.high)
                                .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                                .allowsHitTesting(false)
                        } else if frame == nil {
                            ProgressView().position(x: geo.size.width / 2, y: geo.size.height / 2).allowsHitTesting(false)
                        }
                        cropChrome(fit: fit, scale: scale, area: geo.size)
                    }
                    .offset(pan)
                    if let d = rotation {
                        Text(abs(settings.straighten) < 0.05 ? "0.0°" : String(format: "%+.1f°", settings.straighten))
                            .font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: Capsule())
                            .position(x: d.pointer.x + 30, y: d.pointer.y + 26)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "crop")
                .task(id: key) {
                    // the whole frame turned, flipped and straightened at the view's scale (a few ms)
                    guard let frame else { shown = nil; return }
                    shown = frame.composed(geometry: geometry, straighten: settings.straighten, crop: frameRect, targetScale: scale).map { (key, $0) }
                }
                .onAppear { syncFromModel() }
                .onChange(of: settings) { _, _ in if dragStart == nil, rotation == nil { syncFromModel() } }
            }
            Divider()
            bar
        }
    }

    // MARK: - Drawing

    private func screenRect(_ r: CGRect, fit: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: fit.minX + r.minX * scale, y: fit.minY + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    @ViewBuilder private func cropChrome(fit: CGRect, scale: CGFloat, area: CGSize) -> some View {
        let r = screenRect(rect, fit: fit, scale: scale)
        // darken everything outside the crop
        Path { p in p.addRect(CGRect(x: -3000, y: -3000, width: area.width + 6000, height: area.height + 6000)); p.addRect(r) }   // generous: the view pans while turning
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        // thirds grid (a finer one while straightening, to line things up against) and border
        Path { p in
            let n = fineGrid ? 9 : 3
            for i in 1..<n {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(n), y = r.minY + r.height * CGFloat(i) / CGFloat(n)
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(fineGrid ? 0.3 : 0.35), lineWidth: 0.5)
        .allowsHitTesting(false)
        Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1)
            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
        // move: the inside of the rectangle
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .frame(width: max(1, r.width), height: max(1, r.height)).offset(x: r.minX, y: r.minY)
            .gesture(drag(.move, scale: scale))
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.openHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        // handles
        ForEach(Handle.allCases) { h in
            let p = h.point(in: r)
            Group {
                if h.isCorner {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 12, height: 12)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: h.isVertical ? 5 : 22, height: h.isVertical ? 22 : 5)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .frame(width: 28, height: 28).contentShape(Rectangle())
            .position(p)
            .gesture(drag(h, scale: scale))
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Picker("Aspect", selection: $aspect) {
                ForEach(CropAspect.allCases) { a in Text(a.name).tag(a) }
            }
            .frame(maxWidth: 170)
            .onChange(of: aspect) { _, _ in applyAspect() }
            if lockedRatio != nil, aspect != .square {
                Picker("", selection: $portrait) {
                    Image(systemName: "rectangle").tag(false)
                    Image(systemName: "rectangle.portrait").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                .onChange(of: portrait) { _, _ in applyAspect() }
                .help("Landscape or portrait")
            }
            Divider().frame(height: 18)
            Button { rotate() } label: { Image(systemName: "rotate.left") }.help("Rotate a quarter turn counter-clockwise")
            Button { flip(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip horizontally")
            Button { flip(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.help("Flip vertically")
            Divider().frame(height: 18)
            HStack(spacing: 6) {
                Image(systemName: "level").foregroundStyle(.secondary)
                Slider(value: Binding(get: { settings.straighten }, set: { setStraighten($0) }), in: -45...45, step: 0.1, onEditingChanged: { levelling = $0 })
                    .frame(width: 150).controlSize(.small)
                Text(abs(settings.straighten) < 0.05 ? "0.0°" : String(format: "%+.1f°", settings.straighten)).font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    .foregroundStyle(abs(settings.straighten) < 0.05 ? .secondary : .primary)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { setStraighten(0) }
            }
            .help("Straighten: drag the slider, or drag anywhere outside the crop rectangle to turn the picture; double-click the angle to reset")
            Spacer()
            Text("\(Int(rect.width)) × \(Int(rect.height))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button("Reset") { reset() }.disabled(!photo.hasCustomCrop && rect == photo.frameCrop(for: settings))
            Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Editing

    private func syncFromModel() {
        rect = photo.frameCrop(for: settings)
        if settings.frameCrop == nil { aspect = .freeform }
    }

    /// Store the rectangle; nil when it is just the camera's framing (so it keeps following the defaults).
    private func commit() {
        let c = CropRect(rect, in: geometry.display, minSide: Int(minSide))
        rect = c.cgRect
        var probe = settings; probe.frameCrop = nil
        let def = CropRect(photo.frameCrop(for: probe), in: geometry.display, minSide: Int(minSide))
        settings.frameCrop = c == def ? nil : c
    }

    private func reset() {
        aspect = .freeform; portrait = false
        settings.frameCrop = nil; settings.turns = 0; settings.flipH = false; settings.flipV = false; settings.straighten = 0
        rect = photo.frameCrop(for: settings)
    }

    /// Change the orientation, keeping the framed part of the picture.
    private func reorient(_ change: (inout SPPSettings) -> Void) {
        let before = geometry.toSensor(rect)
        var s = settings; change(&s)
        let g = photo.geometry(for: s)
        rect = g.toDisplay(before).shrunk(toFit: g.straightenedFramePolygon(s.straighten))
        settings = s
        commit()
    }
    private func rotate() { reorient { $0.turns = ($0.turns + 3) % 4 } }   // counter-clockwise, like Photos
    private func flip(horizontal: Bool) {
        reorient { if horizontal { $0.flipH.toggle() } else { $0.flipV.toggle() }; $0.straighten = -$0.straighten }
    }
    private func setStraighten(_ degrees: Double) {
        settings.straighten = min(45, max(-45, (degrees * 10).rounded() / 10))
        rect = rect.shrunk(toFit: polygon)
        commit()
    }

    private func applyAspect() {
        guard let ratio = lockedRatio else { return }
        var r = rect.largestInscribed(ratio: ratio)
        if r.width < minSide * 3 || r.height < minSide * 3 {   // too small to be useful: refit in the whole frame
            r = frameRect.largestInscribed(ratio: ratio)
        }
        rect = r.confined(to: frameRect).shrunk(toFit: polygon)
        commit()
    }

    private func drag(_ h: Handle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
            .onChanged { v in
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart else { return }
                let d = CGSize(width: v.translation.width / scale, height: v.translation.height / scale)
                let r = h == .move ? start.offsetBy(dx: d.width, dy: d.height).confined(to: frameRect)
                                   : resized(start, handle: h, delta: d)
                if r.isInside(polygon: polygon) { rect = r }   // never beyond the (straightened) picture
            }
            .onEnded { _ in
                dragStart = nil
                commit()
            }
    }

    /// Turning the picture by dragging outside the rectangle: the pointer's angle about the rectangle's
    /// centre becomes the straightening angle, and the rectangle is moved so that the picture turns
    /// about its centre (as in Photoshop and Lightroom). On screen the rectangle stays under the pivot —
    /// the view pans by the same amount — and slides home when the drag ends. Within one drag the
    /// rectangle grows back as the angle returns towards zero.
    private func rotateDrag(fit: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("crop"))
            .onChanged { v in
                if rotation == nil {
                    let r = screenRect(rect, fit: fit, scale: scale)
                    let pivot = CGPoint(x: r.midX + pan.width, y: r.midY + pan.height)
                    rotation = RotationDrag(pivot: pivot, startAngle: angle(from: pivot, to: v.startLocation), straighten0: settings.straighten, rect0: rect, pointer: v.location)
                }
                guard var d = rotation else { return }
                d.pointer = v.location; rotation = d
                CropCursor.rotate.set()
                var delta = angle(from: d.pivot, to: v.location) - d.startAngle
                delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180   // the short way round
                let degrees = min(45, max(-45, ((d.straighten0 + delta) * 10).rounded() / 10))
                // the picture point under the rectangle's centre stays there: move the rectangle with it
                let g = geometry
                let c0 = CGPoint(x: d.rect0.midX, y: d.rect0.midY)
                let c1 = c0.applying(g.straighten(d.straighten0).inverted().concatenating(g.straighten(degrees)))
                settings.straighten = degrees
                rect = d.rect0.offsetBy(dx: c1.x - c0.x, dy: c1.y - c0.y).shrunk(toFit: g.straightenedFramePolygon(degrees))
                pan = CGSize(width: -(c1.x - c0.x) * scale, height: -(c1.y - c0.y) * scale)
            }
            .onEnded { _ in
                rotation = nil
                withAnimation(.easeOut(duration: 0.25)) { pan = .zero }
                commit()
            }
    }

    /// The pointer's angle about `c` in degrees, growing clockwise on screen.
    private func angle(from c: CGPoint, to p: CGPoint) -> Double { atan2(Double(p.y - c.y), Double(p.x - c.x)) * 180 / .pi }

    /// The rectangle after dragging `handle` by `delta` (frame pixels), honouring the aspect lock,
    /// the minimum size and the frame.
    private func resized(_ start: CGRect, handle: Handle, delta: CGSize) -> CGRect {
        let frame = frameRect
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(maxX - minSide, max(frame.minX, start.minX + delta.width)) }
        if handle.movesRight { maxX = max(minX + minSide, min(frame.maxX, start.maxX + delta.width)) }
        if handle.movesTop { minY = min(maxY - minSide, max(frame.minY, start.minY + delta.height)) }
        if handle.movesBottom { maxY = max(minY + minSide, min(frame.maxY, start.maxY + delta.height)) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio = lockedRatio else { return r }

        // keep the ratio: corners follow the dominant pointer movement, edges keep their centre line
        let anchorX = handle.movesLeft ? start.maxX : start.minX
        let anchorY = handle.movesTop ? start.maxY : start.minY
        var w = r.width, h = r.height
        if handle.isCorner {
            if w / ratio >= h { h = w / ratio } else { w = h * ratio }
        } else if handle.isVertical {              // left / right edge: width drives
            h = w / ratio
        } else {                                   // top / bottom edge: height drives
            w = h * ratio
        }
        // shrink to what fits in the frame from the anchor
        let roomW = handle.isCorner || handle.isVertical ? (handle.movesLeft ? anchorX - frame.minX : frame.maxX - anchorX)
                                                         : min(start.midX - frame.minX, frame.maxX - start.midX) * 2
        let roomH = handle.isCorner || !handle.isVertical ? (handle.movesTop ? anchorY - frame.minY : frame.maxY - anchorY)
                                                          : min(start.midY - frame.minY, frame.maxY - start.midY) * 2
        if w > roomW { w = roomW; h = w / ratio }
        if h > roomH { h = roomH; w = h * ratio }
        if w < minSide { w = minSide; h = w / ratio }
        if h < minSide { h = minSide; w = h * ratio }
        if handle.isCorner {
            r = CGRect(x: handle.movesLeft ? anchorX - w : anchorX, y: handle.movesTop ? anchorY - h : anchorY, width: w, height: h)
        } else if handle.isVertical {
            r = CGRect(x: handle.movesLeft ? anchorX - w : anchorX, y: start.midY - h / 2, width: w, height: h)
        } else {
            r = CGRect(x: start.midX - w / 2, y: handle.movesTop ? anchorY - h : anchorY, width: w, height: h)
        }
        return r.confined(to: frame)
    }

    static func fitRect(_ size: CGSize, in area: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let s = min(area.width / size.width, area.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, move
        static var allCases: [Handle] { [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight] }
        var id: Self { self }
        var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
        var isVertical: Bool { self == .left || self == .right }   // an edge handle on a vertical side
        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .top: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .left: return CGPoint(x: r.minX, y: r.midY)
            case .right: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottom: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .move: return CGPoint(x: r.midX, y: r.midY)
            }
        }
    }
}

/// Pointer shapes for the crop tool.
enum CropCursor {
    /// Two curved arrows, black with a white outline (legible on any picture), for the turn zone.
    static let rotate: NSCursor = {
        let side: CGFloat = 28
        func glyph(_ color: NSColor) -> NSImage? {
            guard let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Rotate")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .bold)) else { return nil }
            return NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set(); rect.fill(using: .sourceAtop)
                return true
            }
        }
        guard let black = glyph(.black), let white = glyph(.white) else { return .arrow }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let s = black.size
            let r = CGRect(x: ((side - s.width) / 2).rounded(), y: ((side - s.height) / 2).rounded(), width: s.width, height: s.height)
            for dx in [-1.4, 0, 1.4] as [CGFloat] {
                for dy in [-1.4, 0, 1.4] as [CGFloat] where dx != 0 || dy != 0 { white.draw(in: r.offsetBy(dx: dx, dy: dy)) }
            }
            black.draw(in: r)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()
}
