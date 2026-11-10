import Foundation
import Supabase

/// Blank (blank.is): the social network X3F Studio publishes to. Production unless the
/// `blank.environment` default is "development" (Blank's development project, for trying things out).
enum BlankEnvironment: String {
    case production, development

    static var current: BlankEnvironment {
        BlankEnvironment(rawValue: UserDefaults.standard.string(forKey: "blank.environment") ?? "") ?? .production
    }
    var projectRef: String {
        switch self {
        case .production: return "iwxlvjmlzfroegcwusbj"
        case .development: return "wmtelungmdufdfpxizgt"
        }
    }
    /// The project's public (anon) key, as in the Blank apps; row-level security does the guarding.
    var anonKey: String {
        switch self {
        case .production: return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml3eGx2am1semZyb2VnY3d1c2JqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTE1NTcwNjgsImV4cCI6MjA2NzEzMzA2OH0.e_sWZcRv5zB0zJp9sJ7Dz_BJbhewSXVPjyV5AcanLIc"
        case .development: return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndtdGVsdW5nbWR1ZmRmcHhpemd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAxOTkxNTQsImV4cCI6MjA4NTc3NTE1NH0.StbwgqOk00jFmAqjepk7qc0ST8oy6H7HuE4riK_QT0c"
        }
    }
    var url: URL { URL(string: "https://\(projectRef).supabase.co")! }
    var web: URL { URL(string: "https://blank.is")! }
}

enum Blank {
    static let environment = BlankEnvironment.current
    /// Sign in with Apple (web flow) comes back to the app through this URL; the scheme is in Info.plist.
    static let callbackURL = URL(string: "x3fstudio://blank-auth")!
    static let client = SupabaseClient(
        supabaseURL: environment.url, supabaseKey: environment.anonKey,
        options: SupabaseClientOptions(auth: .init(storage: FileAuthStorage(), redirectToURL: callbackURL,
                                                   autoRefreshToken: true, emitLocalSessionAsInitialSession: true)))
    /// The public page of a post: blank.is/username/postId.
    static func postURL(username: String, postID: String) -> URL {
        environment.web.appendingPathComponent(username).appendingPathComponent(postID)
    }
}

/// Keeps the Blank session in Application Support (0600). A locally built, ad-hoc-signed app has no
/// keychain access group, so the SDK's data-protection keychain storage is not available to it.
final class FileAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let dir: URL
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        dir = support.appendingPathComponent("X3F Studio", isDirectory: true)
    }
    private func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return dir.appendingPathComponent("blank-\(String(safe)).json")
    }
    func store(key: String, value: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try value.write(to: file(key), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
    }
    func retrieve(key: String) throws -> Data? { try? Data(contentsOf: file(key)) }
    func remove(key: String) throws { try? FileManager.default.removeItem(at: file(key)) }
}
