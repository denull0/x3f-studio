import SwiftUI

/// The Settings window (⌘,): appearance, the library and export folders, JPEG quality, SIGMA Photo
/// Pro's colour adjustment, and the saved presets.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.name).tag(a) }
                }
                .pickerStyle(.segmented)
                Toggle("Show the photo strip under the editor", isOn: $state.filmstripShown)
            }
            Section("Library") {
                folderRow("Folder", state.library.paths.root)
                HStack {
                    Button("Choose Folder…") { state.chooseLibraryFolder() }
                    Button("Show in Finder") { state.revealLibrary() }
                }
                Text("Imported X3F files are copied here, organised by capture date. The catalog, previews and presets live in its hidden .x3fstudio folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                folderRow("JPEG folder", state.library.paths.exportsDir)
                HStack {
                    Button("Choose Folder…") { state.chooseExportFolder() }
                    if state.exportFolder != nil { Button("Use the Library's Exports Folder") { state.exportFolder = nil } }
                    Button("Show in Finder") { state.revealExports() }
                }
                HStack {
                    Text("JPEG quality")
                    Slider(value: $state.jpegQuality, in: 0.7...1.0, step: 0.01)
                    Text("\(Int((state.jpegQuality * 100).rounded()))%").font(.body.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
                Toggle("Show exported files in the Finder", isOn: $state.revealAfterExport)
            }
            LocalModelSection(tagging: state.tagging)
            if state.blankEnabled {
            Section("Blank") {
                Toggle("Publish to Blank", isOn: $state.blankEnabled)
                Text("Adds Publish to Blank (⇧⌘P) to the toolbar and the Photo menu. Blank (blank.is) is a social network without algorithms or ads; accounts sign in with Apple. Turning this off hides the section; `defaults write com.maybethis.x3fstudio blank.enabled -bool YES` brings it back.")
                    .font(.caption).foregroundStyle(.secondary)
                if state.blankEnabled {
                    if state.blank.isSignedIn {
                        HStack {
                            Text(state.blank.profile.map { "Signed in as @\($0.username)" } ?? "Signed in")
                            Spacer()
                            Button("Sign Out") { Task { await state.blank.signOut() } }
                        }
                    } else {
                        Text("Not signed in. Publishing asks you to sign in with Apple.").foregroundStyle(.secondary)
                    }
                    Picker("Picture size", selection: $state.blankMaxPixel) {
                        ForEach([1800, 2400, 3000], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Text("Pictures are developed with the SIGMA engine like an export, scaled to this longer side and sent as JPEG (90%). Posts appear in your Blank feed and at blank.is/username.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }
            Section("Presets") {
                ForEach(Preset.builtIn) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text((p.colorOnly == true ? "Temperature and Tint only · " : "") + p.adjustments.presetSummary(base: SPPSettings())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("Built in").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if state.library.presets.isEmpty {
                    Text("No presets of your own yet. In the editor, choose Preset ▸ Save Current Adjustments…").foregroundStyle(.secondary)
                }
                ForEach(state.library.presets) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.adjustments.presetSummary(base: SPPSettings())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) { state.library.removePreset(id: p.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this preset")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(url.path)
        }
    }
}

/// Settings ▸ Local Model: the Ollama-based categorising.
struct LocalModelSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var tagging: TaggingService
    var body: some View {
        Group {
                Section("Local Model") {
                    Toggle("Categorise photos and days with a local model", isOn: $tagging.enabled)
                    if tagging.enabled {
                        Toggle("Suggest corrections (exposure, colour cast, tilt, framing)", isOn: $tagging.reviewEnabled)
                    }
                    Text("Runs through Ollama on this Mac: every new photo gets a caption, categories and tags from its thumbnail, and each day gets a title and a summary. With suggestions on, each photo is also reviewed for corrections; a green cast it reports becomes the Less Green preset's Temperature and Tint. Nothing leaves the computer.")
                        .font(.caption).foregroundStyle(.secondary)
                    if tagging.enabled {
                        Picker("Model", selection: $tagging.model) {
                            if tagging.models.isEmpty { Text(tagging.model.isEmpty ? "None found" : tagging.model).tag(tagging.model) }
                            ForEach(tagging.models) { m in Text(m.name + (m.vision ? "" : "  (no vision)")).tag(m.name) }
                        }
                        LabeledContent("Ollama") {
                            HStack {
                                TextField("Address", text: $tagging.endpoint, prompt: Text("http://localhost:11434")).labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                                Button("Check") { Task { await tagging.refreshModels() } }.disabled(tagging.checking)
                            }
                        }
                        switch tagging.status {
                        case .unavailable(let m): Label(m, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        case .running: Text("Categorising \(min(tagging.done + 1, tagging.total)) of \(tagging.total)" + (tagging.current.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                        case .idle:
                            let n = state.library.photos.filter { $0.aiAt != nil }.count
                            let r = state.library.photos.filter { $0.aiAdvice != nil }.count
                            let w = state.library.photos.filter { $0.aiAdvice?.needsWork == true }.count
                            Text("\(n) of \(state.library.photos.count) photos categorised · \(state.library.sessions.count) days titled" + (tagging.reviewEnabled ? " · \(r) reviewed, \(w) with suggestions" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Categorise Missing") { tagging.enqueueMissing() }.disabled(tagging.isRunning)
                            if tagging.reviewEnabled {
                                Button("Review All") { tagging.enqueueReview(state.library.photos.map(\.id)) }.disabled(tagging.isRunning || tagging.modelName.isEmpty).help("Ask the model again what every photo needs, as developed now")
                            }
                            Button("Rename Days") { tagging.renameDays() }.disabled(tagging.isRunning || tagging.modelName.isEmpty).help("Title every day again from the photos' notes")
                            Button("Redo Everything") { tagging.redoAll() }.disabled(tagging.isRunning || tagging.modelName.isEmpty)
                            if tagging.isRunning { Button("Stop") { tagging.stop() } }
                        }
                    }
                }
        }
        .task { if tagging.enabled { await tagging.refreshModels() } }
    }
}
