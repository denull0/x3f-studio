import Foundation
import AppKit
import Combine
import os

/// Categorises photos and days with a local model through Ollama: each photo gets a caption,
/// categories and tags from its thumbnail; once every photo of a day is done, the day gets a title,
/// a summary and categories from those notes. Runs in the background, one request at a time, for
/// new imports and for anything not yet categorised.
@MainActor
final class TaggingService: ObservableObject {
    static let categories = ["street", "portrait", "landscape", "architecture", "nature", "documentary", "still life", "interior", "travel", "family", "night", "abstract", "event"]
    private static let log = Logger(subsystem: "com.maybethis.x3fstudio", category: "tagging")

    enum Status: Equatable { case idle, running, unavailable(String) }
    @Published private(set) var status: Status = .idle
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var current: String?
    @Published private(set) var models: [OllamaModel] = []
    @Published private(set) var checking = false

    private let defaults = UserDefaults.standard
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "ai.enabled") as? Bool ?? true {
        didSet { defaults.set(enabled, forKey: "ai.enabled"); if enabled { enqueueMissing() } else { stop() } }
    }
    @Published var model: String = UserDefaults.standard.string(forKey: "ai.model") ?? "" {
        didSet { defaults.set(model, forKey: "ai.model") }
    }
    @Published var endpoint: String = UserDefaults.standard.string(forKey: "ai.endpoint") ?? "http://localhost:11434" {
        didSet { defaults.set(endpoint, forKey: "ai.endpoint") }
    }

    weak var library: Library?
    /// What the queue holds: describing a photo (caption, categories, tags) or reviewing it for corrections.
    enum Job: Hashable {
        case describe(Photo.ID), review(Photo.ID)
        var id: Photo.ID { switch self { case .describe(let i), .review(let i): return i } }
    }
    private var queue: [Job] = []
    private var queued: Set<Job> = []
    /// After describing a photo, also ask what it needs (Settings ▸ Local Model). Off unless turned on.
    @Published var reviewEnabled: Bool = UserDefaults.standard.object(forKey: "ai.review") as? Bool ?? false {
        didSet { defaults.set(reviewEnabled, forKey: "ai.review"); if reviewEnabled { enqueueMissing() } }
    }
    func isReviewing(_ id: Photo.ID) -> Bool { queued.contains(.review(id)) }
    private var worker: Task<Void, Never>?

    private var client: OllamaClient { OllamaClient(base: URL(string: endpoint) ?? URL(string: "http://localhost:11434")!) }
    var isRunning: Bool { worker != nil }
    var modelName: String { model.isEmpty ? (models.first { $0.vision }?.name ?? "") : model }

    // MARK: - Models

    /// Ask Ollama what is installed; picks a vision model when none is chosen.
    func refreshModels() async {
        checking = true
        defer { checking = false }
        do {
            models = try await client.models()
            if model.isEmpty || !models.contains(where: { $0.name == model }) {
                model = models.first { $0.vision }?.name ?? models.first?.name ?? ""
            }
            if case .unavailable = status { status = .idle }
        } catch {
            models = []
            status = .unavailable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Queue

    /// Everything not yet done: describing (new imports, or all photos the first time) and, when
    /// enabled, reviewing photos that have no suggestion yet.
    func enqueueMissing() {
        guard enabled, let library else { return }
        var jobs: [Job] = library.photos.filter { $0.aiAt == nil }.map { .describe($0.id) }
        if reviewEnabled { jobs += library.photos.filter { $0.aiAt != nil && $0.aiAdvice == nil }.map { .review($0.id) } }
        add(jobs)
    }

    /// New imports: describe them (a review follows each when enabled).
    func enqueue(_ ids: [Photo.ID]) { add(ids.map { .describe($0) }) }

    /// Ask what these photos need; `front` for the one on screen.
    func enqueueReview(_ ids: [Photo.ID], front: Bool = false) { add(ids.map { .review($0) }, front: front) }

    private func add(_ jobs: [Job], front: Bool = false) {
        guard enabled else { return }
        let fresh = jobs.filter { !queued.contains($0) }
        guard !fresh.isEmpty else { return }
        for j in fresh { queued.insert(j) }
        if front { queue.insert(contentsOf: fresh, at: 0) } else { queue.append(contentsOf: fresh) }
        if done >= total { total = 0; done = 0 }
        total += fresh.count
        if worker == nil { worker = Task { await run() } }
    }

    /// Forget every result and start over (a new model, say).
    func redoAll() {
        guard let library else { return }
        stop()
        library.clearAI()
        total = 0; done = 0
        enqueueMissing()
    }

    /// Name every complete day again (after a prompt or model change), keeping the photos' results.
    func renameDays() {
        guard enabled, let library, !isRunning else { return }
        library.clearSessions()
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.current = nil; if self.status == .running { self.status = .idle } }
            if self.models.isEmpty { await self.refreshModels() }
            guard !self.modelName.isEmpty else { return }
            self.status = .running
            var seen = Set<String>()
            for photo in library.photos where !Task.isCancelled {
                let key = Library.dayKey(for: photo.captureDate)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                await self.summariseDayIfReady(of: photo, library: library)
            }
        }
    }

    func stop() {
        worker?.cancel(); worker = nil
        queue.removeAll(); queued.removeAll()
        current = nil
        if status == .running { status = .idle }
    }

    private func run() async {
        defer { worker = nil; current = nil; if status == .running { status = .idle } }
        if models.isEmpty { await refreshModels() }
        guard !modelName.isEmpty else {
            status = .unavailable(models.isEmpty ? "No Ollama models found. In Terminal: ollama pull gemma3:4b" : "No vision-capable model is installed. In Terminal: ollama pull gemma3:4b")
            queue.removeAll(); queued.removeAll(); done = total
            return
        }
        status = .running
        while !queue.isEmpty, !Task.isCancelled {
            let job = queue.removeFirst()
            defer { queued.remove(job); done += 1 }
            guard let library, let photo = library.photo(id: job.id) else { continue }
            do {
                switch job {
                case .describe:
                    current = photo.fileName
                    let result = try await describe(photo, library: library)
                    library.setAI(result, model: modelName, for: job.id)
                    await summariseDayIfReady(of: photo, library: library)
                    if reviewEnabled { add([.review(job.id)]) }
                case .review:
                    current = "Reviewing " + photo.fileName
                    let advice = try await review(photo, library: library)
                    library.setAdvice(advice, for: job.id)
                }
            } catch OllamaClient.Failure.unreachable {
                status = .unavailable(OllamaClient.Failure.unreachable.errorDescription ?? "")
                queue.removeAll(); queued.removeAll(); done = total
                return
            } catch {
                TaggingService.log.error("\(photo.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
                if case OllamaClient.Failure.http(_, let msg) = error, msg.localizedCaseInsensitiveContains("image") {
                    status = .unavailable("The model \(self.modelName) does not take images. Choose a vision model in Settings.")
                    queue.removeAll(); queued.removeAll(); done = total
                    return
                }
            }
        }
    }

    // MARK: - Photos

    struct PhotoNotes: Decodable { let caption: String; let categories: [String]; let tags: [String]; let mood: String? }

    private func describe(_ photo: Photo, library: Library) async throws -> PhotoNotes {
        let url = library.paths.thumb(photo)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw NSError(domain: "X3FStudio", code: 30, userInfo: [NSLocalizedDescriptionKey: "No thumbnail for \(photo.fileName)"])
        }
        let schema: [String: Any] = ["type": "object",
            "properties": ["caption": ["type": "string"], "categories": ["type": "array", "items": ["type": "string"]],
                           "tags": ["type": "array", "items": ["type": "string"]], "mood": ["type": "string"]],
            "required": ["caption", "categories", "tags"]]
        let prompt = """
        You label photographs for a photographer's library. Return JSON with:
        caption — one factual sentence describing the picture;
        categories — 1 to 3 from exactly this list: \(TaggingService.categories.joined(separator: ", "));
        tags — 4 to 8 specific lowercase keywords (subjects, place type, light, season, colours, activity);
        mood — one or two words.
        """
        var notes: PhotoNotes = try await client.chat(model: modelName, prompt: prompt, images: [data], schema: schema, as: PhotoNotes.self)
        notes = PhotoNotes(caption: notes.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                           categories: TaggingService.clean(notes.categories).filter { TaggingService.categories.contains($0) },
                           tags: TaggingService.clean(notes.tags), mood: notes.mood?.lowercased().trimmingCharacters(in: .whitespaces))
        return notes
    }

    private static func clean(_ words: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in words {
            let t = w.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !t.isEmpty, t.count <= 32, !seen.contains(t) else { continue }
            seen.insert(t); out.append(t)
        }
        return out
    }

    // MARK: - Corrections

    struct PhotoReview: Decodable {
        let needs_correction: Bool
        let exposure_ev: Double?
        let white_balance: String?
        let cast_strength: String?
        let tilt_degrees: Double?
        let framing: String?
        let note: String
    }

    /// The model looks at the photo as it is currently developed and says what, if anything, it needs.
    /// Its words become additions to the sliders: EV, colour-grid steps, degrees of straightening.
    private func review(_ photo: Photo, library: Library) async throws -> PhotoAdvice {
        let url = library.paths.thumb(photo)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw NSError(domain: "X3FStudio", code: 31, userInfo: [NSLocalizedDescriptionKey: "No thumbnail for " + photo.fileName])
        }
        let schema: [String: Any] = ["type": "object",
            "properties": ["needs_correction": ["type": "boolean"], "exposure_ev": ["type": "number"], "white_balance": ["type": "string"],
                           "cast_strength": ["type": "string"], "tilt_degrees": ["type": "number"], "framing": ["type": "string"], "note": ["type": "string"]],
            "required": ["needs_correction", "exposure_ev", "white_balance", "tilt_degrees", "note"]]
        let prompt = [
            "You are a careful photo editor reviewing a photograph exactly as it is developed now. Judge only what is visible; most well-exposed photos need nothing. Return JSON with:",
            "needs_correction: true only when a change would clearly improve it;",
            "exposure_ev: how much brighter (+) or darker (-) it should be, in EV from -2 to 2, 0 when fine (be conservative, 0.3 is already noticeable);",
            "white_balance: one of fine, too cool, too warm, too green, too magenta;",
            "cast_strength: slight or strong (when white_balance is not fine);",
            "tilt_degrees: how far a horizon or the verticals lean clockwise, from -10 to 10, 0 when level or when there is no straight reference;",
            "framing: fine, or one short suggestion such as crop tighter on the left;",
            "note: one plain sentence, the main issue and the fix, or Looks good.",
        ].joined(separator: "\n")
        let r: PhotoReview = try await client.chat(model: modelName, prompt: prompt, images: [data], schema: schema, temperature: 0.1, as: PhotoReview.self)
        let strong = (r.cast_strength ?? "").lowercased().contains("strong")
        let step = strong ? 4.0 : 2.0
        var temperature = 0.0, tint = 0.0
        let wb = (r.white_balance ?? "fine").lowercased()
        if wb.contains("cool") { temperature = step } else if wb.contains("warm") { temperature = -step }
        else if wb.contains("magenta") { tint = step }
        else if wb.contains("green") {
            // the Less Green preset's move, as a change to the current sliders
            let c = photo.settings.colorAdjustment ?? SPPColorAdjustment(), g = Preset.lessGreen.adjustments.colorAdjustment ?? SPPColorAdjustment()
            temperature = g.x - c.x; tint = g.y - c.y
        }
        let note = r.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ev = max(-2, min(2, ((r.exposure_ev ?? 0) * 10).rounded() / 10))
        let tilt = max(-10, min(10, ((r.tilt_degrees ?? 0) * 10).rounded() / 10))
        var framing = r.framing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if framing.lowercased().hasPrefix("fine") || framing.lowercased() == "none" { framing = "" }
        var advice = PhotoAdvice(needsWork: r.needs_correction, exposure: ev, temperature: temperature, tint: tint, straighten: -tilt,
                                 framing: framing.isEmpty ? nil : framing, note: note,
                                 model: modelName, at: Date())
        if advice.isEmpty { advice.needsWork = false }   // nothing concrete to apply
        return advice
    }

    // MARK: - Days

    struct DayNotes: Decodable { let title: String; let summary: String; let categories: [String] }

    /// Once every photo of the day is categorised (and the day has no up-to-date summary), name the day.
    private func summariseDayIfReady(of photo: Photo, library: Library) async {
        let key = Library.dayKey(for: photo.captureDate)
        let photos = library.photos.filter { Library.dayKey(for: $0.captureDate) == key }
        guard !photos.isEmpty, photos.allSatisfy({ $0.aiAt != nil }) else { return }
        if let s = library.session(forKey: key), s.photoCount == photos.count { return }
        current = "Summing up \(photo.captureDate.formatted(date: .abbreviated, time: .omitted))"
        let sorted = photos.sorted { $0.captureDate < $1.captureDate }
        let cameras = Set(photos.map(\.camera.model)).sorted().joined(separator: ", ")
        let span = "\(sorted.first!.captureDate.formatted(date: .omitted, time: .shortened))–\(sorted.last!.captureDate.formatted(date: .omitted, time: .shortened))"
        let notes = sorted.prefix(60).enumerated().map { i, p in
            "\(i + 1). \(p.aiCaption ?? "") [\(p.aiTags.joined(separator: ", "))]"
        }.joined(separator: "\n")
        let prompt = """
        A photographer shot these \(photos.count) photos on \(photo.captureDate.formatted(date: .complete, time: .omitted)) (\(span)) with \(cameras). Notes per photo:
        \(notes)

        Return JSON with: title — a short gallery-style name of 2 to 5 words for this set, naming the place, subject or moment (like "Notting Hill in Autumn Light" or "Mira's First Walk"); never use the words session, photography, photos, collection, series or exploration, and no date, camera or quotes; summary — one plain sentence about the set as a whole; categories — 1 to 3 from exactly this list: \(TaggingService.categories.joined(separator: ", ")).
        """
        let schema: [String: Any] = ["type": "object",
            "properties": ["title": ["type": "string"], "summary": ["type": "string"], "categories": ["type": "array", "items": ["type": "string"]]],
            "required": ["title", "summary", "categories"]]
        do {
            let day: DayNotes = try await client.chat(model: modelName, prompt: prompt, schema: schema, temperature: 0.4, as: DayNotes.self)
            let info = SessionInfo(title: day.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”."))),
                                   summary: day.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                   categories: TaggingService.clean(day.categories).filter { TaggingService.categories.contains($0) },
                                   model: modelName, at: Date(), photoCount: photos.count)
            library.setSession(info, forKey: key)
        } catch {
            TaggingService.log.error("day \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
