import Foundation

/// A local Ollama server (http://localhost:11434 by default): the model list and structured-JSON chat
/// with optional images. Everything stays on this Mac.
struct OllamaModel: Identifiable, Hashable {
    let name: String
    var vision: Bool
    var id: String { name }
}

struct OllamaClient: Sendable {
    let base: URL

    enum Failure: LocalizedError {
        case unreachable, http(Int, String), badReply
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Ollama isn't running. Open the Ollama app (or run `ollama serve`)."
            case .http(let code, let msg): return "Ollama: \(msg.isEmpty ? "HTTP \(code)" : msg)"
            case .badReply: return "Ollama returned something unexpected."
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600; c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()
    private var session: URLSession { OllamaClient.session }

    /// Installed models, with whether each one accepts images.
    func models() async throws -> [OllamaModel] {
        let tags: TagsReply = try await get("api/tags")
        var out: [OllamaModel] = []
        for m in tags.models {
            let show: ShowReply? = try? await post("api/show", body: ["model": m.name])
            out.append(OllamaModel(name: m.name, vision: show?.capabilities?.contains("vision") ?? false))
        }
        return out.sorted { $0.vision != $1.vision ? $0.vision : $0.name < $1.name }
    }

    /// One chat turn with a JSON schema for the answer; `images` are JPEG/PNG bytes.
    func chat<T: Decodable>(model: String, prompt: String, images: [Data] = [], schema: [String: Any], temperature: Double = 0.2, as type: T.Type) async throws -> T {
        var message: [String: Any] = ["role": "user", "content": prompt]
        if !images.isEmpty { message["images"] = images.map { $0.base64EncodedString() } }
        let body: [String: Any] = ["model": model, "messages": [message], "stream": false, "format": schema,
                                   "keep_alive": "15m", "options": ["temperature": temperature]]
        let reply: ChatReply = try await post("api/chat", body: body)
        guard let data = reply.message.content.data(using: .utf8) else { throw Failure.badReply }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Failure.badReply }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path)); req.timeoutInterval = 5
        return try await send(req)
    }
    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }
    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw Failure.unreachable }
        guard let http = resp as? HTTPURLResponse else { throw Failure.badReply }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw Failure.badReply }
    }
}

private struct TagsReply: Decodable { struct M: Decodable { let name: String }; let models: [M] }
private struct ShowReply: Decodable { let capabilities: [String]? }
private struct ChatReply: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
private struct ErrorReply: Decodable { let error: String? }
