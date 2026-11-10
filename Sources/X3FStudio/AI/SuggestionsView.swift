import SwiftUI

/// The local model's review of the photo in the editor: its note, the proposed changes, and Apply.
/// Nothing is applied until the button is pressed; Dismiss keeps the note but drops the flag.
struct SuggestionsRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: EditorModel

    private var id: Photo.ID { model.photo.id }
    private var advice: PhotoAdvice? { state.library.photo(id: id)?.aiAdvice }
    private var reviewing: Bool { state.tagging.isReviewing(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: advice?.needsWork == true ? "wand.and.stars" : "checkmark.circle")
                    .foregroundStyle(advice?.needsWork == true ? Color.orange : Color.secondary)
                Text(advice == nil ? "Suggestions" : advice!.needsWork ? "Suggested" : "Reviewed").font(.callout)
                Spacer()
                if reviewing {
                    ProgressView().controlSize(.small)
                } else if state.tagging.enabled {
                    Button { state.tagging.enqueueReview([id], front: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(advice == nil ? "Ask the local model what this photo needs" : "Review again, as developed now")
                }
            }
            if let a = advice {
                Text(a.note).font(.caption).foregroundStyle(.secondary)
                if a.needsWork, !a.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(a.changes, id: \.self) { TagChip(tag: $0) }
                    }
                    HStack {
                        Button("Apply") { apply(a) }.controlSize(.small).buttonStyle(.borderedProminent)
                        Button("Dismiss") { state.library.settleAdvice(for: id) }.controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            } else if !reviewing {
                Text(state.tagging.enabled ? "The local model can say whether this photo needs a correction." : "Turn on the local model in Settings to get suggestions.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// Add the suggested changes to the current settings (the engine re-renders as usual).
    private func apply(_ a: PhotoAdvice) {
        var s = model.settings
        if abs(a.exposure) >= 0.05 { s.exposure = min(3, max(-3, ((s.exposure + a.exposure) * 10).rounded() / 10)) }
        if abs(a.temperature) >= 0.25 || abs(a.tint) >= 0.25 {
            let c = s.colorAdjustment ?? SPPColorAdjustment()
            func clamp(_ v: Double) -> Double { min(SPPColorAdjustment.range.upperBound, max(SPPColorAdjustment.range.lowerBound, (v * 2).rounded() / 2)) }
            s.colorAdjustment = SPPColorAdjustment(x: clamp(c.x + a.temperature), y: clamp(c.y + a.tint))
        }
        if abs(a.straighten) >= 0.05 { s.straighten = min(45, max(-45, ((s.straighten + a.straighten) * 10).rounded() / 10)) }
        model.settings = s
        state.library.settleAdvice(for: id)
    }
}
