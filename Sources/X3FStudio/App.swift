import SwiftUI

@main
struct X3FStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state: AppState

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        AppDelegate.state = s
    }

    var body: some Scene {
        // One library, one window: a WindowGroup kept restoring extra copies of it at launch.
        Window("X3F Studio", id: "main") {
            ContentView().tint(.primary)   // no blue: controls take the label colour
                .environmentObject(state)
                .preferredColorScheme(state.appearance.colorScheme)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        Settings {
            SettingsView().tint(.primary).environmentObject(state).preferredColorScheme(state.appearance.colorScheme)
        }
        // Its own window, not a sheet: the Apple sign-in sheet attaches to it.
        Window("Publish to Blank", id: "publish") {
            PublishWindow().tint(.primary).environmentObject(state).preferredColorScheme(state.appearance.colorScheme)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Photos…") { state.importViaPanel() }.keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("Export JPEG") { state.exportSelected() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.exportCandidates.isEmpty)
                Button("Export JPEG To…") { state.exportViaPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(state.exportCandidates.isEmpty)
                Button("Show Exports in Finder") { state.revealExports() }
            }
            CommandMenu("Photo") {
                Button("Open") { if let id = state.selection.first, state.editingID == nil { state.open(id) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(state.selection.count != 1 || state.editingID != nil)
                Button("Back to Library") { state.closeEditor() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(state.editingID == nil)
                Divider()
                Button("Previous Photo") { state.step(-1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(state.editingID == nil)
                Button("Next Photo") { state.step(1) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(state.editingID == nil)
                Toggle("Show Photo Strip", isOn: $state.filmstripShown).disabled(state.editingID == nil)
                Divider()
                Button(state.targetsAllFlagged ? "Unflag" : "Flag") { state.toggleFlag() }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(state.targetIDs.isEmpty || state.textEditing)
                Menu("Rating") {
                    ForEach(0...5, id: \.self) { n in
                        Toggle(n == 0 ? "No Rating" : String(repeating: "★", count: n),
                               isOn: Binding(get: { state.targetsRating == n }, set: { _ in state.setRating(n) }))
                            .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
                    }
                }
                .disabled(state.targetIDs.isEmpty || state.textEditing)
                Menu("Tags") {
                    ForEach(state.library.allTags, id: \.tag) { t in
                        Toggle(t.tag, isOn: Binding(get: { state.targetsHaveTag(t.tag) }, set: { on in on ? state.addTags(t.tag) : state.removeTag(t.tag) }))
                    }
                    if !state.library.allTags.isEmpty { Divider() }
                    Button("New Tag…") { state.promptNewTag() }.keyboardShortcut("k", modifiers: .command)
                }
                .disabled(state.targetIDs.isEmpty)
                Divider()
                Menu("Apply Preset") {
                    ForEach(state.library.presets) { p in Button(p.name) { state.applyPreset(p) } }
                    if !state.library.presets.isEmpty { Divider() }
                    ForEach(Preset.builtIn) { p in Button(p.name) { state.applyPreset(p) } }
                }
                .disabled(state.targetIDs.isEmpty)
                Button("Save Adjustments as Preset…") { state.askPresetName = true }
                    .disabled(state.editingID == nil || state.editingPhoto?.engine.isSupported != true)
                if state.blankEnabled {
                    Divider()
                    Button("Publish to Blank…") { state.publishToBlank() }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                        .disabled(state.targetIDs.isEmpty)
                }
                Divider()
                Button(state.cropMode ? "Done Cropping" : "Crop") { state.toggleCrop() }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(state.editingID == nil || state.editingPhoto?.engine.isSupported != true || state.textEditing)
                Divider()
                Button("Re-render with Engine") { state.rerenderSelected() }.disabled(state.exportCandidates.isEmpty)
                Divider()
                Button("Remove from Library…") { state.removeSelected() }.keyboardShortcut(.delete, modifiers: .command).disabled(state.exportCandidates.isEmpty)
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom to Fit") { state.zoom(.fit) }.keyboardShortcut("0", modifiers: .command).disabled(state.editingID == nil)
                Button("Actual Size") { state.zoom(.actualSize) }.keyboardShortcut("1", modifiers: .command).disabled(state.editingID == nil)
                Button("Zoom In") { state.zoom(.zoomIn) }.keyboardShortcut("=", modifiers: .command).disabled(state.editingID == nil)
                Button("Zoom Out") { state.zoom(.zoomOut) }.keyboardShortcut("-", modifiers: .command).disabled(state.editingID == nil)
                Divider()
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.name).tag(a) }
                }
                Divider()
            }
            CommandMenu("Library") {
                Toggle("Show Flagged Only", isOn: $state.showFlaggedOnly).keyboardShortcut("f", modifiers: [.command, .shift])
                Picker("Minimum Rating", selection: $state.minRating) {
                    Text("Any Rating").tag(0)
                    ForEach(1...5, id: \.self) { n in Text(String(repeating: "★", count: n) + (n < 5 ? " and up" : "")).tag(n) }
                }
                Picker("Tag", selection: $state.tagFilter) {
                    Text("Any Tag").tag(String?.none)
                    ForEach(state.library.allTags, id: \.tag) { t in Text("\(t.tag) (\(t.count))").tag(Optional(t.tag)) }
                }
                Button("Show All Photos") { state.clearFilters() }.disabled(!state.isFiltering)
                Divider()
                Button("Show Library in Finder") { state.revealLibrary() }
                Button("Choose Library Folder…") { state.chooseLibraryFolder() }
            }
        }
    }
}
