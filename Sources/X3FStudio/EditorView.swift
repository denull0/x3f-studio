import SwiftUI
import AppKit

/// Drives the engine for one photo: quick renders while adjusting, a full-quality render once idle.
@MainActor
final class EditorModel: ObservableObject {
    enum Quality { case placeholder, quick, final }

    @Published var settings = SPPSettings()
    @Published private(set) var image: CGImage?
    @Published private(set) var quality: Quality = .placeholder
    @Published private(set) var isRendering = false
    @Published private(set) var errorText: String?
    /// The whole frame in sensor orientation, for the crop tool (which turns and straightens it itself).
    @Published private(set) var frameImage: EngineImage?

    /// The crop tool is open: quick renders show the whole frame and the final render waits for Done.
    var cropping = false {
        didSet {
            guard cropping != oldValue else { return }
            if cropping {
                preCropImage = image; preCropQuality = quality; preCropCrop = settings
                image = nil; quality = .placeholder; frameImage = nil   // the whole-frame render arrives in a moment
            } else if let img = preCropImage, preCropCrop == settings {
                image = img; quality = preCropQuality   // nothing changed: keep what was on screen
            } else {
                image = nil; quality = .placeholder     // a new crop: the trimmed render replaces it in a moment
            }
            preCropImage = nil
            finalFor = nil
            requestRender(initial: true)
        }
    }
    private var preCropImage: CGImage?
    private var preCropQuality: Quality = .placeholder
    private var preCropCrop: SPPSettings?

    private(set) var photo: Photo
    private weak var state: AppState?
    /// The image area in device pixels, reported by the view. Quick renders are made at the size the
    /// photo takes when fitted into it (RenderService.quickSize), like SIGMA Photo Pro's review window.
    var viewPixels = CGSize(width: 1600, height: 1200) { didSet { viewportDidChange() } }
    private var viewportKnown = false

    private var dirty = false
    private var loop: Task<Void, Never>?
    private var refine: Task<Void, Never>?
    private var refineSerial = 0
    private var quickBusy = false { didSet { isRendering = quickBusy || refineBusy } }
    private var refineBusy = false { didSet { isRendering = quickBusy || refineBusy } }
    private var lastQuickSize: (w: Int, h: Int)?   // size of the latest quick render requested
    private var finalFor: SPPSettings?             // settings of the final image on screen, if one is

    init(photo: Photo, state: AppState) {
        self.photo = photo
        self.state = state
        settings = photo.settings
        let paths = state.library.paths
        // show something at once: the last engine preview, or the camera's own JPEG
        if let img = RawImage.cgImage(file: paths.preview(photo), maxPixel: 2048) ?? RawImage.cgImage(file: paths.thumb(photo), maxPixel: 640) {
            image = img
        }
        if photo.engine.isSupported { requestRender(initial: true) }
    }

    func settingsDidChange() {
        guard photo.engine.isSupported else { return }
        state?.library.setSettings(settings, for: photo.id)
        if let p = state?.library.photo(id: photo.id) { photo = p }
        if cropping { return }   // the whole-frame preview doesn't depend on the crop; renders resume on Done
        requestRender(initial: false)
    }

    func resetToCamera() { settings = photo.asShot }

    /// The editor moved on to another photo (or back to the library): no more renders for this one.
    /// A render already with an engine still finishes and is cached; nothing new is started.
    func stop() {
        stopped = true
        dirty = false
        loop?.cancel(); loop = nil
        refine?.cancel(); refine = nil
    }
    private var stopped = false

    private func requestRender(initial: Bool) {
        guard !stopped else { return }
        dirty = true
        finalFor = nil   // whatever is on screen no longer matches the settings (or the colour adjustment)
        refine?.cancel(); refine = nil
        if loop == nil { loop = Task { await self.runLoop(initialDelay: initial ? 0 : 90) } }
    }

    /// A window resize changes the fit size. While a quick image is on screen, re-render it when it
    /// would otherwise be upscaled noticeably (the final image covers any size; zooming never changes
    /// the view size, so a zoomed-in quick image stays scaled until the final arrives).
    private func viewportDidChange() {
        viewportKnown = true
        guard photo.engine.isSupported, let state, let last = lastQuickSize, finalFor != settings.quantized() else { return }
        let want = state.renders.quickSize(for: photo, settings: settings.quantized(), fitting: viewPixels, wholeFrame: cropping)
        guard Double(want.w) > Double(last.w) * 1.15 || Double(want.h) > Double(last.h) * 1.15 else { return }
        dirty = true
        if loop == nil { loop = Task { await self.runLoop(initialDelay: 150) } }   // lets a live resize settle
    }

    private func runLoop(initialDelay: Int) async {
        if initialDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(initialDelay) * 1_000_000) }
        // the first render waits (briefly) for the view to report its size, so it is made at the fit size
        for _ in 0..<20 where !viewportKnown { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard let state else { return }
        while dirty {
            dirty = false
            let s = settings.quantized(), px = viewPixels, whole = cropping
            lastQuickSize = state.renders.quickSize(for: photo, settings: s, fitting: px, wholeFrame: whole)
            quickBusy = true
            do {
                let e = try await state.renders.quickRender(photo, settings: s, maxDevicePixels: px, wholeFrame: whole)
                if whole {
                    if !dirty { frameImage = e; errorText = nil }
                } else if !dirty, finalFor != s {   // never replace a final image of the same settings (a resize pass can finish after it)
                    image = e.composed(geometry: photo.geometry(for: s), straighten: s.straighten, crop: photo.frameCrop(for: s))
                    quality = .quick; errorText = nil; finalFor = nil
                }
            } catch {
                errorText = error.localizedDescription
                if case EngineServer.Failure.notInstalled = error { dirty = false }
            }
            quickBusy = false
        }
        loop = nil
        if refine == nil, !cropping { scheduleRefine() }   // a refine still running (resize pass) stays valid
    }

    private func scheduleRefine() {
        guard !stopped else { return }
        refine?.cancel()
        refineSerial += 1
        let serial = refineSerial
        refine = Task {
            defer { if refineSerial == serial { refine = nil } }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let state else { return }
            let s = settings.quantized()
            refineBusy = true
            defer { refineBusy = false }
            do {
                // the finals' own engine: quick renders never queue behind it, and on a Quattro file a
                // final that follows another final of the same photo takes ~50 ms instead of seconds
                let tiff = try await state.renders.fullRender(photo, settings: s, on: state.renders.final)
                guard !Task.isCancelled, s == settings.quantized() else { return }
                // full resolution, so zooming to 100% is sharp; turned, flipped, straightened and cropped here
                let p = photo
                let img = await Task.detached(priority: .userInitiated) { RenderService.finalImage(photo: p, settings: s, tiff: tiff) }.value
                guard !Task.isCancelled, s == settings.quantized() else { return }
                guard let img else { errorText = "Couldn't read the full-quality render"; return }
                image = img; quality = .final; errorText = nil; finalFor = s
                await state.renders.updateDerivatives(for: photo, from: tiff)
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var state: AppState
    let photoID: Photo.ID
    @StateObject private var model: EditorModel
    @State private var presetName = ""

    init(photoID: Photo.ID, state: AppState) {
        self.photoID = photoID
        // the model is created once per photo (ContentView applies .id(photoID))
        let photo = state.library.photo(id: photoID)!
        _model = StateObject(wrappedValue: EditorModel(photo: photo, state: state))
    }

    private var subtitle: String {
        return model.photo.camera.summary
    }

    private var isFlagged: Bool { state.library.photo(id: photoID)?.flagged ?? false }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        state.library.addPreset(name: name.isEmpty ? model.settings.presetSummary(base: model.photo.asShot) : name, adjustments: model.settings)
    }

    var body: some View {
        HStack(spacing: 0) {
            if state.cropMode {
                CropEditorArea(frame: model.frameImage, photo: model.photo, settings: $model.settings, onDone: { state.cropMode = false })
            } else {
                ImageArea(model: model)
            }
            Divider()
            AdjustmentsPanel(model: model)
                .frame(width: 280)
                .background(Color(nsColor: .windowBackgroundColor))
                .disabled(state.cropMode)
                .opacity(state.cropMode ? 0.5 : 1)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.closeEditor() } label: { Label("Library", systemImage: "chevron.left") }.help("Back to the library (esc)")
                Button { state.step(-1) } label: { Image(systemName: "chevron.up") }.help("Previous photo (⌘←)")
                Button { state.step(1) } label: { Image(systemName: "chevron.down") }.help("Next photo (⌘→)")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings (⌘,)")
            }
            // the flag and the stars in the centre of the header, each in its own container
            ToolbarItem(placement: .principal) {
                Button { state.toggleFlag([photoID]) } label: { Label(isFlagged ? "Unflag" : "Flag", systemImage: isFlagged ? "flag.fill" : "flag") }
                    .help(isFlagged ? "Unflag (P)" : "Flag (P)")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .principal)   // keeps the flag out of the stars' container
            }
            ToolbarItem(placement: .principal) {
                StarRating(rating: state.library.photo(id: photoID)?.rating ?? 0, size: 14) { state.setRating($0, [photoID]) }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 24)
                    .help("Rating: click a star, or press 1–5 (0 clears)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.toggleCrop() } label: { Label("Crop", systemImage: state.cropMode ? "crop.rotate" : "crop") }
                    .help(state.cropMode ? "Done cropping (C)" : "Crop (C)")
                    .disabled(!model.photo.engine.isSupported)
                if state.blankEnabled {
                    Button { state.publishToBlank([photoID]) } label: { Label("Publish to Blank", systemImage: "paperplane") }
                        .help("Publish this photo as a Blank post (⇧⌘P)")
                }
                Button { state.exportSelected() } label: { Label("Export JPEG", systemImage: "photo.badge.arrow.down") }
                    .help("Export full-size JPEG to the library's Exports folder (⌘E)")
                    .disabled(state.exportProgress != nil)
                ShareButton(enabled: state.exportProgress == nil) { view in state.share(anchor: view) }
            }
        }
        .navigationTitle(model.photo.fileName)
        .navigationSubtitle(subtitle)
        .onChange(of: model.settings) { _, _ in model.settingsDidChange() }
        .onChange(of: state.cropMode) { _, on in model.cropping = on }
        .onAppear { model.cropping = state.cropMode }
        .onDisappear { model.stop() }
        .onKeyPress(.escape) { if state.cropMode { state.cropMode = false } else { state.closeEditor() }; return .handled }
        .onKeyPress(.leftArrow) { state.step(-1); return .handled }
        .onKeyPress(.rightArrow) { state.step(1); return .handled }
        .onKeyPress(.upArrow) { state.step(-1); return .handled }
        .onKeyPress(.downArrow) { state.step(1); return .handled }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters {
            case ".": state.toggleFlag([photoID]); return .handled   // Photos' favourite key
            case "u": state.unflag([photoID]); return .handled       // Lightroom's unflag key
            default: return .ignored
            }
        }
        .onChange(of: state.presetCommand) { _, c in if let c { model.settings = model.settings.applying(c.preset) } }
        .onChange(of: state.askPresetName) { _, on in state.textEditing = on; if on { presetName = model.settings.presetSummary(base: model.photo.asShot) } }
        .alert("Save Preset", isPresented: $state.askPresetName) {
            TextField("Name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this photo's sliders, white balance, colour mode, temperature and tint, to apply to other photos. The crop and rotation are not included.")
        }
    }
}

struct ImageArea: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: EditorModel
    @State private var zoom: CGFloat = 0
    // The carousel: while fitted, the picture follows a sideways swipe, the neighbouring photo's
    // preview comes in beside it, and on release it snaps to that photo (or back). The step itself
    // happens once the slide has finished; the new editor then opens on the same preview, in place.
    @State private var slide: CGFloat = 0                 // the picture's sideways offset, points
    @State private var sliding = false                    // a swipe or its snap is in progress
    @State private var neighbours: [Int: CGImage] = [:]   // −1: the previous photo's preview, +1: the next
    private let gap: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ZoomableImageView(image: model.image, fullPixelSize: model.photo.displaySize, zoomCommand: state.zoomCommand,
                                  onViewportChange: { px in model.viewPixels = px },
                                  onZoomChange: { z in zoom = z },
                                  onSwipe: { swipe($0, width: w) })
                if sliding {
                    // While the strip moves it is plain SwiftUI drawing laid over the scroll view, which
                    // stays where it is and keeps receiving the gesture: the current picture as rendered
                    // now and the neighbours' previews, in one layer, so nothing lags behind or jumps.
                    ZStack {
                        Color(white: 0.11)
                        ForEach([-1, 0, 1], id: \.self) { d in
                            if let img = d == 0 ? model.image : neighbours[d] {
                                Image(decorative: img, scale: 1)
                                    .resizable().interpolation(.high).scaledToFit()
                                    .frame(width: w, height: h)
                                    .offset(x: slide + CGFloat(d) * (w + gap))
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                overlays
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .task(id: model.photo.id) { await loadNeighbours() }
    }

    @ViewBuilder private var overlays: some View {
        Group {
            if model.image == nil { ProgressView() }
            VStack {
                if model.isRendering { ProgressView().progressViewStyle(.linear).tint(.white.opacity(0.7)).frame(height: 2) }
                Spacer()
                HStack {
                    Spacer()
                    Text(zoom > 0 ? "\(Int((zoom * 100).rounded()))%" : "")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(10)
                        .help("Pinch or ⌘-scroll to zoom · double-click for 100% · ⌘0 fit · swipe sideways for the next photo")
                }
            }
            if !model.photo.engine.isSupported {
                VStack { Spacer()
                    Text("No SIGMA Photo Pro engine here develops this X3F (dp Quattro and Merrill files are). Showing the camera's own JPEG.")
                        .font(.callout).padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                }
            }
        }
    }

    /// The previews of both neighbours, read in the background so a swipe can start at once.
    private func loadNeighbours() async {
        var files: [Int: URL] = [:]
        for d in [-1, 1] {
            guard let id = state.neighbour(d), let p = state.library.photo(id: id) else { continue }
            let paths = state.library.paths
            let preview = paths.preview(p), thumb = paths.thumb(p)
            files[d] = FileManager.default.fileExists(atPath: preview.path) ? preview : thumb
        }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [Int: CGImage] in
            var out: [Int: CGImage] = [:]
            for (d, url) in files { if let img = RawImage.cgImage(file: url, maxPixel: 2048) { out[d] = img } }
            return out
        }.value
        neighbours = loaded
    }

    private func swipe(_ e: SwipeEvent, width w: CGFloat) {
        switch e {
        case .changed(let dx):
            let d = dx < 0 ? 1 : -1
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                sliding = true
                slide = state.canStep(d) ? dx : dx * 0.25   // rubber band at either end of the strip
            }
        case .ended(let dx, let velocity):
            let d = dx < 0 ? 1 : -1
            let flick = abs(velocity) > 500 && (velocity < 0) == (dx < 0)
            if state.canStep(d), abs(dx) > w * 0.3 || flick {
                withAnimation(.spring(duration: 0.32, bounce: 0)) { slide = CGFloat(-d) * (w + gap) } completion: { state.step(d) }
            } else {
                withAnimation(.spring(duration: 0.3, bounce: 0.15)) { slide = 0 } completion: { sliding = false }
            }
        case .cancelled:
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { slide = 0 } completion: { sliding = false }
        }
    }
}

struct AdjustmentsPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: EditorModel

    private var photo: Photo { model.photo }
    private var engineDisabled: Bool { !photo.engine.isSupported }
    /// The preset pop-up: the preset these adjustments match ("None" when none does); choosing one
    /// applies it, None returns to the camera's own adjustments, the last entry saves a new preset.
    private var presetSelection: Binding<String> {
        Binding(get: { state.library.allPresets.first { $0.matches(model.settings) }?.id.uuidString ?? "none" },
                set: { tag in
                    switch tag {
                    case "save": state.askPresetName = true
                    case "none": model.settings = model.settings.applying(adjustmentsOf: photo.asShot)
                    default: if let p = state.library.allPresets.first(where: { $0.id.uuidString == tag }) { model.settings = model.settings.applying(p) }
                    }
                })
    }

    /// One line of the info sheet: a light monospaced label in a fixed column, the value beside it.
    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .light, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
        }
    }
    /// The info sheet's rows, in order.
    private var infoRows: [(String, String)] {
        var rows: [(String, String)] = [("CAMERA", photo.camera.model)]
        if let lens = lensText { rows.append(("LENS", lens)) }
        if let exposure = exposureText { rows.append(("EXPOSURE", exposure)) }
        rows.append(("TAKEN", photo.captureDate.formatted(date: .abbreviated, time: .shortened)))
        rows.append(("SIZE", "\(Int(photo.displaySize.width)) × \(Int(photo.displaySize.height))"))
        rows.append(("FILE", photo.fileName + (photo.fileSize > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(photo.fileSize), countStyle: .file) : "")))
        return rows
    }
    /// A section title in the same light monospace; with `expanded`, the row folds the section and
    /// carries its chevron on the right.
    private func sectionHeader(_ title: String, expanded: Binding<Bool>? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .light)).tracking(1.5).foregroundStyle(.secondary)
            Spacer()
            if let expanded {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .light)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let expanded { withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() } } }
        .help(expanded == nil ? "" : "Show or hide this section")
    }
    /// A thin, light rule.
    private var hairline: some View { Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5) }
    /// The lens and focal length, when the file says.
    private var lensText: String? {
        let c = photo.camera
        // the camera's lens name usually carries the focal length already ("30mm F2.8")
        var s = c.lens.trimmingCharacters(in: .whitespaces)
        if s.isEmpty, c.focalLength > 0 { s = String(format: "%.0f mm", c.focalLength) }
        if !s.isEmpty, c.focalLength35 > 0, c.focalLength35 != Int(c.focalLength.rounded()) { s += " (\(c.focalLength35) mm eq.)" }
        return s.isEmpty ? nil : s
    }
    /// Shutter, aperture and ISO, when the file says.
    private var exposureText: String? {
        let c = photo.camera
        var parts: [String] = []
        if c.exposureTime > 0 { parts.append(c.exposureTime >= 1 ? String(format: "%.0f s", c.exposureTime) : "1/\(Int((1 / c.exposureTime).rounded())) s") }
        if c.fNumber > 0 { parts.append(String(format: "ƒ/%.1f", c.fNumber)) }
        if c.iso > 0 { parts.append("ISO \(c.iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// A label on the left, its pop-up on the right; every pop-up the same width.
    private func settingRow<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            control().labelsHidden().frame(width: 150)
        }
    }

    /// The photo's Temperature/Tint; neutral is the camera's colour as the engine develops it.
    private var baseColor: SPPColorAdjustment { SPPColorAdjustment() }
    private var colorX: Binding<Double> {
        Binding(get: { model.settings.colorAdjustment?.x ?? baseColor.x },
                set: { setColor(SPPColorAdjustment(x: $0, y: model.settings.colorAdjustment?.y ?? baseColor.y)) })
    }
    private var colorY: Binding<Double> {
        Binding(get: { model.settings.colorAdjustment?.y ?? baseColor.y },
                set: { setColor(SPPColorAdjustment(x: model.settings.colorAdjustment?.x ?? baseColor.x, y: $0)) })
    }
    /// Neutral is no adjustment at all, so a slider brought back to 0 leaves the photo unedited.
    private func setColor(_ c: SPPColorAdjustment) { model.settings.colorAdjustment = c.isNeutral ? nil : c }
    /// The camera/date/size block is folded unless opened; the choice carries over between photos.
    @AppStorage("editor.infoShown") private var infoShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // INFO: a spec sheet in monospace behind a header with its chevron on the right,
                    // folded unless opened; thin rules between the rows
                    sectionHeader("INFO", expanded: $infoShown)
                    if infoShown {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(infoRows.enumerated()), id: \.offset) { i, row in
                                infoLine(row.0, row.1).padding(.vertical, 7)
                                if i < infoRows.count - 1 { hairline }
                            }
                        }
                        .padding(.top, 6)
                        if let cap = state.library.photo(id: photo.id)?.aiCaption, !cap.isEmpty {
                            Text(cap).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 14)
                                .help("Described by \(state.library.photo(id: photo.id)?.aiModel ?? "the local model")")
                        }
                        TagsEditor(photoID: photo.id).padding(.top, 20)
                    }
                    if state.tagging.reviewEnabled { SuggestionsRow(model: model).padding(.top, 20) }
                    hairline.padding(.vertical, 24)
                    // EDIT: preset, white balance, colour mode, then the sliders
                    sectionHeader("EDIT")
                    VStack(alignment: .leading, spacing: 12) {
                        settingRow("Preset") {
                            Picker("", selection: presetSelection) {
                                Text("None").tag("none")
                                if !state.library.presets.isEmpty {
                                    Divider()
                                    ForEach(state.library.presets) { p in Text(p.name).tag(p.id.uuidString) }
                                }
                                Divider()
                                ForEach(Preset.builtIn) { p in Text(p.name).tag(p.id.uuidString) }
                                Divider()
                                Text("Save Current Adjustments…").tag("save")
                            }
                            .help("Apply a saved set of adjustments (None: the camera's own), or save this photo's as a preset. Presets are removed in Settings.")
                        }
                        settingRow("White Balance") {
                            Picker("", selection: $model.settings.whiteBalance) {
                                ForEach(WhiteBalance.allCases) { wb in Text(wb.name).tag(wb.rawValue) }
                                if WhiteBalance(rawValue: model.settings.whiteBalance) == nil { Text(WhiteBalance.name(for: model.settings.whiteBalance)).tag(model.settings.whiteBalance) }
                            }
                        }
                        settingRow("Color Mode") {
                            Picker("", selection: $model.settings.colorMode) {
                                ForEach(ColorMode.allCases) { cm in Text(cm.name).tag(cm.rawValue) }
                                if ColorMode(rawValue: model.settings.colorMode) == nil { Text(ColorMode.name(for: model.settings.colorMode)).tag(model.settings.colorMode) }
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.top, 14)
                    VStack(alignment: .leading, spacing: 18) {
                        SliderRow(title: "Exposure", value: $model.settings.exposure, range: -3...3, format: "%+.1f", unit: "EV", neutral: photo.asShot.exposure)
                        SliderRow(title: "Contrast", value: $model.settings.contrast, range: -2...2, neutral: photo.asShot.contrast)
                        SliderRow(title: "Shadows", value: $model.settings.shadow, range: -2...2, neutral: photo.asShot.shadow)
                        SliderRow(title: "Highlights", value: $model.settings.highlight, range: -2...2, neutral: photo.asShot.highlight)
                        SliderRow(title: "Saturation", value: $model.settings.saturation, range: -2...2, neutral: photo.asShot.saturation)
                        SliderRow(title: "Sharpness", value: $model.settings.sharpness, range: -2...2, neutral: photo.asShot.sharpness)
                        SliderRow(title: "Fill Light", value: $model.settings.fillLight, range: -2...2, neutral: photo.asShot.fillLight)
                    }
                    .padding(.top, 24)
                    hairline.padding(.vertical, 24)
                    // COLOR: SIGMA Photo Pro's Color Adjustment grid as two sliders, in its units
                    sectionHeader("COLOR")
                    VStack(alignment: .leading, spacing: 18) {
                    SliderRow(title: "Temperature", value: colorX, range: SPPColorAdjustment.range, step: 0.5, neutral: baseColor.x,
                              display: SPPColorAdjustment.temperatureReadout, help: "Blue ← → Amber, in SIGMA Photo Pro's grid units. Double-click to reset.",
                              colors: ColorAxis.temperature)
                    SliderRow(title: "Tint", value: colorY, range: SPPColorAdjustment.range, step: 0.5, neutral: baseColor.y,
                              display: SPPColorAdjustment.tintReadout, help: "Magenta ← → Green, in SIGMA Photo Pro's grid units. Double-click to reset.",
                              colors: ColorAxis.tint)
                    if photo.hasCustomCrop {
                        HStack {
                            Text(model.settings.isOriented ? "Crop & Rotate" : "Crop").font(.callout)
                            Spacer()
                            Text("\(Int(photo.displaySize.width)) × \(Int(photo.displaySize.height))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Reset") {
                                model.settings.frameCrop = nil; model.settings.turns = 0; model.settings.flipH = false; model.settings.flipV = false; model.settings.straighten = 0
                            }.controlSize(.small)
                        }
                    }
                    }
                    .padding(.top, 14)
                }
                .padding(16)
                .disabled(engineDisabled)
                .opacity(engineDisabled ? 0.5 : 1)
            }
            Divider()
            HStack {
                Button("Reset to Camera") { model.resetToCamera() }
                    .disabled(engineDisabled || model.settings.quantized() == photo.asShot)
                Spacer()
                statusLabel
            }
            .padding(12)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        if let e = model.errorText {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(e)
        } else {
            switch model.quality {
            case .placeholder: Text("…").font(.caption2).foregroundStyle(.tertiary)
            case .quick: Text("quick preview").font(.caption2).foregroundStyle(.secondary)
            case .final: Text("SIGMA engine · final").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%+.1f"
    var unit: String = ""
    var step: Double = 0.1
    var neutral: Double = 0
    var display: ((Double) -> String)? = nil
    var help: String = "Double-click to reset to the camera's value"
    /// For a colour axis: the colours at the slider's two ends. The track becomes a gradient between
    /// them and a swatch next to the value shows the shift the value makes.
    var colors: (low: Color, high: Color)? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                if let c = colors { ColorSwatch(value: value, range: range, low: c.low, high: c.high) }
                Text(display?(value) ?? (String(format: format, value == 0 ? 0 : value) + (unit.isEmpty ? "" : " \(unit)")))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(abs(value - neutral) < 0.05 ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = neutral }
            .help(help)
            if let c = colors {
                ColorAxisSlider(value: $value, range: range, step: step, neutral: neutral, low: c.low, high: c.high)
            } else {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.small)
            }
        }
    }
}

/// The colours of SIGMA Photo Pro's colour grid axes, for the Temperature and Tint sliders.
enum ColorAxis {
    static let blue = Color(red: 0.30, green: 0.55, blue: 1.00)
    static let amber = Color(red: 1.00, green: 0.70, blue: 0.20)
    static let magenta = Color(red: 0.95, green: 0.35, blue: 0.85)
    static let green = Color(red: 0.35, green: 0.85, blue: 0.40)
    static let neutral = Color(white: 0.55)
    /// Temperature: blue (negative) to amber (positive).
    static let temperature: (low: Color, high: Color) = (blue, amber)
    /// Tint: magenta (negative) to green (positive).
    static let tint: (low: Color, high: Color) = (magenta, green)
}

/// A slider whose track shows what the value does: a gradient from `low` through neutral grey to `high`,
/// a tick at the neutral point, and a knob on the current value. Drag or click anywhere on the track.
struct ColorAxisSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    var neutral: Double = 0
    let low: Color
    let high: Color

    private let knob: CGFloat = 14
    private let trackHeight: CGFloat = 6

    private func fraction(_ v: Double) -> CGFloat { CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = geo.size.height / 2
            let travel = max(1, w - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [low, ColorAxis.neutral, high], startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: w, height: trackHeight)
                    .position(x: w / 2, y: mid)
                Rectangle().fill(.primary.opacity(0.45))
                    .frame(width: 1, height: trackHeight + 6)
                    .position(x: knob / 2 + fraction(neutral) * travel, y: mid)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .position(x: knob / 2 + fraction(value) * travel, y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = min(1, max(0, (g.location.x - knob / 2) / travel))
                let raw = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
                let snapped = (raw / step).rounded() * step
                if snapped != value { value = snapped }
            })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.1f", value)))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// A small circle in the colour the slider's value shifts the picture towards; grey at neutral.
struct ColorSwatch: View {
    let value: Double
    let range: ClosedRange<Double>
    let low: Color
    let high: Color
    var body: some View {
        let span = max(1, value < 0 ? -range.lowerBound : range.upperBound)
        let strength = min(1, abs(value) / span)
        ZStack {
            Circle().fill(ColorAxis.neutral.opacity(0.5))
            Circle().fill((value < 0 ? low : high).opacity(strength))
            Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5)
        }
        .frame(width: 11, height: 11)
        .padding(.trailing, 2)
    }
}
