import SwiftUI

/// What an export is for. Each kind has its own file and its own place in the export folder, so a
/// print copy and a web copy of the same photo never overwrite each other.
enum ExportKind: String, CaseIterable, Identifiable {
    /// 16-bit TIFF at full size, for a printer driver, Photoshop or a lab that takes TIFFs.
    case print
    /// sRGB JPEG with its longest side limited (Settings ▸ Export), for sites and social networks.
    case web
    /// Full-size JPEG at the quality set in Settings: what "Export JPEG" always made.
    case jpeg

    var id: Self { self }

    /// Subfolder of the export folder; full-size JPEGs stay in the folder itself, where they always went.
    var subfolder: String? {
        switch self {
        case .print: return "Print"
        case .web: return "Web"
        case .jpeg: return nil
        }
    }
    func folder(in exports: URL) -> URL { subfolder.map { exports.appendingPathComponent($0, isDirectory: true) } ?? exports }

    /// For photos an engine develops; the others export the camera's own JPEG whatever the kind.
    var fileExtension: String { self == .print ? "tif" : "jpg" }

    /// Title in the File menu.
    var command: String {
        switch self {
        case .print: return "Export for Print"
        case .web: return "Export for Web/Social"
        case .jpeg: return "Export Full-Size JPEG"
        }
    }
    /// Title inside an Export menu.
    var title: String {
        switch self {
        case .print: return "For Print"
        case .web: return "For Web/Social"
        case .jpeg: return "Full-Size JPEG"
        }
    }
}

struct ExportOptions {
    var kind: ExportKind
    /// Quality of the full-size JPEG (Settings ▸ Export).
    var jpegQuality = 0.92
    /// Longest side of a web/social JPEG in pixels (Settings ▸ Export).
    var webLongEdge = 2048

    /// The sizes Settings offers: Instagram's width, two common web sizes, and a large one for
    /// high-density screens.
    static let webLongEdges = [1080, 1600, 2048, 3000]
    /// Web/social copies are recompressed by the sites that show them, so they need less than the
    /// full-size JPEG's quality. At 85% three test photos came to 0.6 to 1.1 MB at 2048 px and one
    /// to 0.2 MB at 1080 px (19 Nov 2026).
    static let webQuality = 0.85
}

/// The toolbar's export button: a menu of what the export is for.
struct ExportMenu: View {
    @EnvironmentObject var state: AppState
    let enabled: Bool

    var body: some View {
        Menu {
            Button("For Print · 16-bit TIFF") { state.exportSelected(.print) }
            Button("For Web/Social · \(String(state.webLongEdge)) px JPEG") { state.exportSelected(.web) }
            Button("Full-Size JPEG") { state.exportSelected(.jpeg) }
        } label: {
            Label("Export", systemImage: "photo.badge.arrow.down")
        }
        .help("Export for print (⌥⌘E), for web/social (⌃⌘E) or as a full-size JPEG (⌘E)")
        .accessibilityLabel("Export")   // a toolbar menu otherwise announces its symbol's name
        .disabled(!enabled)
    }
}
