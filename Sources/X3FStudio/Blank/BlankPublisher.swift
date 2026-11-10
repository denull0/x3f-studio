import Foundation
import AppKit
import Supabase

/// Where a photo went on Blank.
struct BlankPostRef: Codable, Equatable, Hashable {
    var id: String
    var username: String
    var publishedAt: Date
    var url: URL { Blank.postURL(username: username, postID: id) }
}

/// Makes a Blank post out of photos: each is developed from its 16-bit master (like an export),
/// scaled to the chosen size, uploaded to Blank's `storage` bucket under the user's folder, and the
/// post with its image blocks (and optional notes block) is inserted — the same rows the Blank apps
/// write, so it shows up in the feed, the profile and on blank.is.
@MainActor
final class BlankPublisher: ObservableObject {
    enum Stage: Equatable {
        case idle
        case developing(Int, Int)
        case uploading(Int, Int)
        case saving
        case done(BlankPostRef)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .developing, .uploading, .saving: return true
            default: return false
            }
        }
        var text: String {
            switch self {
            case .idle: return ""
            case .developing(let i, let n): return "Developing \(i) of \(n) with the SIGMA engine…"
            case .uploading(let i, let n): return "Uploading \(i) of \(n)…"
            case .saving: return "Saving the post…"
            case .done: return "Published."
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var stage: Stage = .idle

    func reset() { stage = .idle }

    func publish(photos: [Photo], caption: String, notes: Bool, draft: Bool = false, maxPixel: Int,
                 account: BlankAccount, renders: RenderService, library: Library) async {
        guard let uid = account.userID, let profile = account.profile else { stage = .failed("Sign in to Blank first."); return }
        guard !profile.username.isEmpty else { stage = .failed("Finish setting up your Blank profile (choose a username) in the Blank app first."); return }
        guard !photos.isEmpty else { stage = .failed("Nothing to publish."); return }
        let client = Blank.client
        let now = Date()
        let iso = ISO8601DateFormatter()
        let owner = uid.uuidString.lowercased()
        var uploaded: [(photo: Photo, path: String, width: Int, height: Int)] = []
        do {
            for (i, photo) in photos.enumerated() {
                stage = .developing(i + 1, photos.count)
                let (data, w, h) = try await develop(photo, maxPixel: maxPixel, renders: renders, library: library)
                stage = .uploading(i + 1, photos.count)
                let path = "\(owner)/x3f_\(photo.id.lowercased())_\(Int(now.timeIntervalSince1970)).jpg"
                _ = try await client.storage.from("storage").upload(path, data: data, options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
                uploaded.append((photo, path, w, h))
            }
            stage = .saving
            let postID = UUID().uuidString.lowercased()
            let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let post = PostRow(id: postID, owner_id: owner, caption: text.isEmpty ? nil : text,
                               content_type: uploaded.count > 1 ? "gallery" : "image", draft: draft,
                               created_at: iso.string(from: now), updated_at: iso.string(from: now))
            try await client.from("posts").insert(post).execute()
            var blocks: [BlockRow] = uploaded.enumerated().map { i, u in
                BlockRow(id: UUID().uuidString.lowercased(), post_id: postID, owner_id: owner, position: i, type: "image", text: nil,
                         media_path: u.path, image_layout: "full", image_size: ImageSize(width: u.width, height: u.height),
                         created_at: iso.string(from: now), updated_at: iso.string(from: now))
            }
            if notes {
                blocks.append(BlockRow(id: UUID().uuidString.lowercased(), post_id: postID, owner_id: owner, position: blocks.count, type: "text",
                                       text: BlankPublisher.notes(for: photos), media_path: nil, image_layout: "full", image_size: nil,
                                       created_at: iso.string(from: now), updated_at: iso.string(from: now)))
            }
            do {
                try await client.from("post_content_blocks").insert(blocks).execute()
            } catch {
                _ = try? await client.from("posts").delete().eq("id", value: postID).execute()   // no post without its pictures
                throw error
            }
            let ref = BlankPostRef(id: postID, username: profile.username, publishedAt: now)
            library.markPublished(ref, ids: Set(photos.map(\.id)))
            stage = .done(ref)
        } catch {
            let paths = uploaded.map(\.path)
            if !paths.isEmpty { _ = try? await client.storage.from("storage").remove(paths: paths) }
            stage = .failed(BlankAccount.describe(error))
        }
    }

    // MARK: - Pictures

    /// The photo as a JPEG for Blank: developed like an export (crop, turns, straightening applied),
    /// no longer than `maxPixel`, with the camera's metadata. Files no engine develops send the camera JPEG.
    private func develop(_ photo: Photo, maxPixel: Int, renders: RenderService, library: Library) async throws -> (Data, Int, Int) {
        let original = library.paths.original(photo)
        let tmp = library.paths.tmpDir.appendingPathComponent("blank-\(UUID().uuidString.prefix(8)).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let image: CGImage
        if photo.engine.isSupported {
            let tiff = try await renders.fullRender(photo, settings: photo.settings, on: renders.background)
            let settings = photo.settings, p = photo
            guard let img = await Task.detached(priority: .userInitiated, operation: { RenderService.finalImage(photo: p, settings: settings, tiff: tiff, maxPixel: maxPixel) }).value else {
                throw NSError(domain: "X3FStudio", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not read the developed image of \(photo.fileName)"])
            }
            image = img
        } else {
            guard let x = try? X3FFile(url: original), let jpeg = x.embeddedThumbnail(maxPixel: maxPixel) else {
                throw NSError(domain: "X3FStudio", code: 11, userInfo: [NSLocalizedDescriptionKey: "No image could be read from \(photo.fileName)"])
            }
            image = jpeg
        }
        try JPEGExport.write(image: image, to: tmp, photo: photo, original: original, quality: 0.90)
        return (try Data(contentsOf: tmp), image.width, image.height)
    }

    /// The notes block: camera and development settings per photo.
    static func notes(for photos: [Photo]) -> String {
        var lines: [String] = []
        for p in photos {
            var parts = [p.camera.model]
            let exposure = p.camera.summary
            if !exposure.isEmpty { parts.append(exposure) }
            let look = p.settings.presetSummary(base: p.asShot)
            if look != "As Shot" { parts.append(look) }
            if p.hasCustomCrop { parts.append(p.settings.isOriented && p.settings.frameCrop == nil ? "rotated" : "cropped") }
            lines.append((photos.count > 1 ? "\((p.fileName as NSString).deletingPathExtension) · " : "") + parts.joined(separator: " · "))
        }
        lines.append("Developed with X3F Studio and SIGMA Photo Pro's engine.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Rows (Blank's tables)

    private struct PostRow: Encodable {
        let id: String; let owner_id: String; let caption: String?; let content_type: String; let draft: Bool
        let created_at: String; let updated_at: String
    }
    private struct ImageSize: Encodable { let width: Int; let height: Int }
    private struct BlockRow: Encodable {
        let id: String; let post_id: String; let owner_id: String; let position: Int; let type: String; let text: String?
        let media_path: String?; let image_layout: String; let image_size: ImageSize?
        let created_at: String; let updated_at: String
    }
}
