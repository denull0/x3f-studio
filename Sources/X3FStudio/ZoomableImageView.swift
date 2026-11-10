import SwiftUI
import AppKit
import QuartzCore

enum ZoomAction { case fit, actualSize, zoomIn, zoomOut }
struct ZoomCommand: Equatable { let action: ZoomAction; let serial: Int }

/// A sideways two-finger swipe over a fitted picture, for the editor's carousel. Travel is in points,
/// positive when the fingers move right.
enum SwipeEvent {
    case changed(CGFloat)
    case ended(CGFloat, velocity: CGFloat)   // travel and speed (points per second) as the fingers lift
    case cancelled
}

/// Pinch-to-zoom / pan image view built on NSScrollView's native magnification.
/// The document keeps a constant size (the photo's full size at 1 image pixel per screen pixel),
/// so swapping a quick preview for the final render never moves the view.
struct ZoomableImageView: NSViewRepresentable {
    var image: CGImage?
    var fullPixelSize: CGSize          // developed size after rotation, in image pixels
    var zoomCommand: ZoomCommand?
    var onViewportChange: (CGSize) -> Void   // visible area in device pixels
    var onZoomChange: (CGFloat) -> Void      // magnification relative to 1 image px = 1 device px
    var onSwipe: ((SwipeEvent) -> Void)? = nil   // a sideways swipe while fitted (the carousel)

    func makeNSView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.onViewportChange = onViewportChange
        v.onZoomChange = onZoomChange
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ v: ZoomScrollView, context: Context) {
        v.onViewportChange = onViewportChange
        v.onZoomChange = onZoomChange
        v.onSwipe = onSwipe
        v.setFullPixelSize(fullPixelSize)
        v.setImage(image)
        if let c = zoomCommand, c.serial != context.coordinator.lastSerial {
            context.coordinator.lastSerial = c.serial
            v.perform(c.action)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastSerial = 0 }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = ImageLayerView()
    private var fullPixelSize = CGSize(width: 4816, height: 3616)
    private(set) var fitMode = true
    var onViewportChange: ((CGSize) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onSwipe: ((SwipeEvent) -> Void)?
    private var lastReportedViewport = CGSize.zero
    private var lastReportedZoom: CGFloat = -1
    private var swipeX: CGFloat = 0, swipeY: CGFloat = 0, swipeVelocity: CGFloat = 0, swipeLastTime: TimeInterval = 0
    private var swipeActive = false, swipeVertical = false

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        documentView = imageView
        drawsBackground = true
        backgroundColor = NSColor(white: 0.11, alpha: 1)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 8
        usesPredominantAxisScrolling = false
        imageView.scrollOwner = self
        postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(userMagnified), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Document size in points so that magnification 1 shows one image pixel per device pixel.
    private var documentPointSize: CGSize { CGSize(width: fullPixelSize.width / backingScale, height: fullPixelSize.height / backingScale) }

    func setFullPixelSize(_ s: CGSize) {
        guard s.width > 0, s.height > 0, s != fullPixelSize || imageView.frame.size == .zero else { return }
        fullPixelSize = s
        imageView.frame = CGRect(origin: .zero, size: documentPointSize)
        if fitMode { zoomToFit() }
    }

    func setImage(_ img: CGImage?) { imageView.image = img }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageView.frame = CGRect(origin: .zero, size: documentPointSize)
        imageView.layer?.contentsScale = backingScale
        if fitMode { zoomToFit() }
    }

    override func layout() {
        super.layout()
        if fitMode { zoomToFit() }
        reportViewport()
    }

    func perform(_ action: ZoomAction) {
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        switch action {
        case .fit: zoomToFit()
        case .actualSize: fitMode = false; setMagnification(1, centeredAt: center)
        case .zoomIn: fitMode = false; setMagnification(min(maxMagnification, magnification * 1.4), centeredAt: center)
        case .zoomOut:
            let fit = fitMagnification
            let m = magnification / 1.4
            if m <= fit { zoomToFit() } else { fitMode = false; setMagnification(m, centeredAt: center) }
        }
        reportZoom()
    }

    var fitMagnification: CGFloat {
        let clip = bounds.size, doc = documentPointSize
        guard clip.width > 0, clip.height > 0, doc.width > 0, doc.height > 0 else { return 1 }
        return min(clip.width / doc.width, clip.height / doc.height)
    }

    func zoomToFit() {
        fitMode = true
        let m = fitMagnification
        if abs(magnification - m) > 0.0001 { magnification = m }
        // keep the (smaller) document centred
        contentView.scroll(to: CGPoint(x: -max(0, (contentView.bounds.width - imageView.frame.width) / 2),
                                       y: -max(0, (contentView.bounds.height - imageView.frame.height) / 2)))
        reflectScrolledClipView(contentView)
        reportZoom()
    }

    /// Double-click: toggle between fit and 100 % around the clicked point (document coordinates).
    func toggleActualSize(at docPoint: CGPoint) {
        if magnification < 0.98 || fitMode && fitMagnification < 0.98 {
            fitMode = false
            setMagnification(1, centeredAt: docPoint)
        } else {
            zoomToFit()
        }
        reportZoom()
    }

    @objc private func userMagnified() { fitMode = false }
    @objc private func liveMagnifyEnded() {
        // snap back to "fit" when the user pinches out past the fitting size
        if magnification <= fitMagnification + 0.001 { zoomToFit() }
        reportZoom()
    }
    @objc private func boundsChanged() { reportZoom() }

    override func magnify(with event: NSEvent) {
        fitMode = false
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ + scroll = zoom, like most image viewers
        if event.modifierFlags.contains(.command) {
            fitMode = false
            let factor = 1 + (event.scrollingDeltaY > 0 ? 0.06 : -0.06) * min(3, abs(event.scrollingDeltaY) / 3 + 1)
            let p = contentView.convert(event.locationInWindow, from: nil)
            let m = min(maxMagnification, max(minMagnification, magnification * factor))
            setMagnification(m, centeredAt: p)
            if m <= fitMagnification + 0.001 { zoomToFit() }
            reportZoom()
            return
        }
        // Fitted, so there is nothing to pan: a two-finger swipe sideways drives the editor's carousel
        // (the picture follows the fingers, the neighbour comes in, release snaps). Only trackpad
        // gestures (events with a phase) that start out sideways; a vertical scroll and the momentum
        // tail are left alone.
        if fitMode, onSwipe != nil, event.phase != [] || event.momentumPhase != [] {
            guard event.momentumPhase == [] else { return }
            switch event.phase {
            case .began, .mayBegin:
                swipeX = 0; swipeY = 0; swipeVelocity = 0; swipeActive = false; swipeVertical = false
                swipeLastTime = event.timestamp
            case .changed:
                swipeX += event.scrollingDeltaX; swipeY += event.scrollingDeltaY
                let dt = max(0.001, event.timestamp - swipeLastTime); swipeLastTime = event.timestamp
                let v = event.scrollingDeltaX / dt
                swipeVelocity = swipeVelocity == 0 ? v : swipeVelocity * 0.6 + v * 0.4
                if !swipeActive, !swipeVertical {
                    if abs(swipeY) > 12, abs(swipeY) > abs(swipeX) { swipeVertical = true }
                    else if abs(swipeX) > 8, abs(swipeX) > abs(swipeY) { swipeActive = true }
                }
                if swipeActive { onSwipe?(.changed(swipeX)) }
            case .ended:
                if swipeActive { onSwipe?(.ended(swipeX, velocity: swipeVelocity)) }
                swipeActive = false
            case .cancelled:
                if swipeActive { onSwipe?(.cancelled) }
                swipeActive = false
            default: break
            }
            return
        }
        super.scrollWheel(with: event)
    }

    /// Three-finger swipes (when the trackpad is set to swipe between pages with three fingers): a
    /// whole step at once.
    override func swipe(with event: NSEvent) {
        guard fitMode, let onSwipe else { super.swipe(with: event); return }
        let w = bounds.width
        if event.deltaX < 0 { onSwipe(.ended(-w, velocity: -3000)) } else if event.deltaX > 0 { onSwipe(.ended(w, velocity: 3000)) }
    }

    // Callbacks hop to the next run-loop turn: they are often triggered from inside SwiftUI's
    // updateNSView, where mutating SwiftUI state is not allowed.
    private func reportViewport() {
        let px = CGSize(width: bounds.width * backingScale, height: bounds.height * backingScale)
        if abs(px.width - lastReportedViewport.width) > 2 || abs(px.height - lastReportedViewport.height) > 2 {
            lastReportedViewport = px
            DispatchQueue.main.async { [weak self] in self?.onViewportChange?(px) }
        }
    }

    private func reportZoom() {
        let m = magnification
        if abs(m - lastReportedZoom) > 0.0005 {
            lastReportedZoom = m
            DispatchQueue.main.async { [weak self] in self?.onZoomChange?(m) }
        }
    }
}

/// Keeps a document smaller than the clip view centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let d = doc.frame
        if r.width > d.width { r.origin.x = d.minX - (r.width - d.width) / 2 }
        if r.height > d.height { r.origin.y = d.minY - (r.height - d.height) / 2 }
        return r
    }
}

final class ImageLayerView: NSView {
    weak var scrollOwner: ZoomScrollView?
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let owner = scrollOwner {
            owner.toggleActualSize(at: convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }
}
