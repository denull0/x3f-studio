import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false
    @State private var newTag = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // NavigationStack gives the window a real toolbar for the views' .toolbar/.navigationTitle to fill.
        NavigationStack {
            ZStack {
                if let id = state.editingID, state.library.photo(id: id) != nil {
                    VStack(spacing: 0) {
                        EditorView(photoID: id, state: state).id(id)
                        Filmstrip()
                    }
                    .transition(.opacity)
                } else {
                    LibraryGridView()
                }
                if dropTargeted { DropOverlay() }
                if let p = state.exportProgress { ExportOverlay(progress: p) }
            }
            .animation(.easeOut(duration: 0.15), value: state.editingID)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                    else if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(u) }
                }
                if !urls.isEmpty { await state.importURLs(urls) }
            }
            return true
        }
        .alert(item: $state.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .onChange(of: state.publishRequest?.id) { _, id in if id != nil { openWindow(id: "publish") } }
        .onChange(of: state.askNewTag) { _, on in state.textEditing = on }
        .alert("New Tag", isPresented: $state.askNewTag) {
            TextField("Tag", text: $newTag)
            Button("Add") { state.addTags(newTag, to: state.newTagTargets); newTag = "" }
            Button("Cancel", role: .cancel) { newTag = "" }
        } message: {
            Text("Added to \(state.newTagTargets.count) photo\(state.newTagTargets.count == 1 ? "" : "s"). Separate several tags with commas.")
        }
        .confirmationDialog("Remove \(state.pendingRemoval?.count ?? 0) photo\((state.pendingRemoval?.count ?? 0) == 1 ? "" : "s") from the library?",
                            isPresented: Binding(get: { state.pendingRemoval != nil }, set: { if !$0 { state.pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove and Move Files to Trash", role: .destructive) { state.confirmRemoval(deleteFiles: true) }
            Button("Remove from Library Only") { state.confirmRemoval(deleteFiles: false) }
            Button("Cancel", role: .cancel) { state.pendingRemoval = nil }
        } message: {
            Text("\"Remove from Library Only\" keeps the X3F files in the library folder.")
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(16)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 36, weight: .light))
                Text("Drop to import").font(.title3)
                Text("X3F files or folders · organised by capture date").font(.callout).foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}

struct ExportOverlay: View {
    let progress: AppState.ExportProgress
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                .frame(width: 260)
            Text(progress.total == 1 ? "Rendering with the SIGMA engine…" : "Exporting \(min(progress.done + 1, progress.total)) of \(progress.total)")
                .font(.callout)
            if !progress.name.isEmpty { Text(progress.name).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }
}

/// Share button that anchors the system share picker to itself.
struct ShareButton: NSViewRepresentable {
    let enabled: Bool
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        b.bezelStyle = .texturedRounded
        b.isBordered = true
        b.toolTip = "Share JPEG"
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }
    func updateNSView(_ b: NSButton, context: Context) { b.isEnabled = enabled; context.coordinator.action = action }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 40, height: 28) }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func tap(_ sender: NSView) { action(sender) }
    }
}
