import Foundation
import AppKit
import Supabase
import os

/// The signed-in Blank user: session state, the profile (username for post links), and the two
/// ways in — a code sent to the account's email, or Sign in with Apple through the web flow.
@MainActor
final class BlankAccount: ObservableObject {
    struct Profile: Equatable {
        let id: UUID
        let username: String
        let email: String?
    }

    @Published private(set) var isSignedIn = false
    @Published private(set) var profile: Profile?
    @Published private(set) var busy = false
    @Published var error: String?
    /// An email a code was sent to, awaiting the code.
    @Published private(set) var codeSentTo: String?

    private var listener: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.maybethis.x3fstudio", category: "blank")

    init() {
        listener = Task { [weak self] in
            for await (event, session) in Blank.client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session {
                        self.isSignedIn = true
                        await self.loadProfile(userID: session.user.id)
                    } else {
                        self.isSignedIn = false; self.profile = nil
                    }
                case .signedOut:
                    self.isSignedIn = false; self.profile = nil
                default:
                    break
                }
            }
        }
    }

    var userID: UUID? { Blank.client.auth.currentUser?.id }

    // MARK: - Sign in

    /// Email a one-time code to an existing Blank account (no accounts are created from here).
    func sendCode(to email: String) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.contains(".") else { error = "Enter the email address of your Blank account."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await Blank.client.auth.signInWithOTP(email: address, shouldCreateUser: false)
            codeSentTo = address
        } catch {
            self.error = BlankAccount.describe(error)
        }
    }

    func verify(code: String) async {
        guard let email = codeSentTo else { return }
        let token = code.filter(\.isNumber)
        guard token.count >= 6 else { error = "Enter the code from the email."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await Blank.client.auth.verifyOTP(email: email, token: token, type: .email)
            codeSentTo = nil
        } catch {
            self.error = BlankAccount.describe(error)
        }
    }

    func useAnotherEmail() { codeSentTo = nil; error = nil }

    /// Sign in with Apple in the default browser: Supabase's authorize URL opens there, Apple signs the
    /// user in (usually one click, the Mac already knows the Apple ID), and Supabase sends the browser
    /// back to `x3fstudio://blank-auth?code=…`, which the app receives and exchanges for a session.
    /// Needs the Apple provider's web credentials (Services ID and key) and the callback URL in the
    /// allowed redirect URLs of Blank's Supabase project.
    @Published private(set) var awaitingBrowser = false
    private var browserContinuation: CheckedContinuation<URL, Error>?

    func signInWithApple() async {
        busy = true; error = nil
        defer { busy = false; awaitingBrowser = false }
        do {
            try await Blank.client.auth.signInWithOAuth(provider: .apple, redirectTo: Blank.callbackURL) { [weak self] url in
                guard let self else { throw CancellationError() }
                BlankAccount.log.notice("apple sign-in: opening in the browser")
                return try await self.openInBrowserAndWait(url)
            }
            BlankAccount.log.notice("apple sign-in: session received")
        } catch {
            BlankAccount.log.error("apple sign-in failed: \(String(describing: error), privacy: .public)")
            self.error = BlankAccount.describe(error)
        }
    }

    private func openInBrowserAndWait(_ url: URL) async throws -> URL {
        browserContinuation?.resume(throwing: CancellationError())
        awaitingBrowser = true
        NSWorkspace.shared.open(url)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in browserContinuation = c }
    }

    /// The browser came back with the callback URL (see `AppDelegate.application(_:open:)`).
    func handleCallback(_ url: URL) {
        guard url.scheme?.lowercased() == Blank.callbackURL.scheme else { return }
        BlankAccount.log.notice("apple sign-in: callback received")
        NSApp.activate(ignoringOtherApps: true)
        if let c = browserContinuation {
            browserContinuation = nil
            c.resume(returning: url)
        } else {
            // no sign-in waiting (the app was relaunched meanwhile): still try to use it
            Task { do { try await Blank.client.auth.session(from: url) } catch { self.error = BlankAccount.describe(error) } }
        }
    }

    func cancelSignIn() {
        browserContinuation?.resume(throwing: CancellationError())
        browserContinuation = nil
    }

    func signOut() async {
        try? await Blank.client.auth.signOut()
        isSignedIn = false; profile = nil; codeSentTo = nil
    }

    // MARK: - Profile

    private func loadProfile(userID: UUID) async {
        struct Row: Decodable { let id: UUID; let username: String?; let email: String? }
        do {
            let row: Row = try await Blank.client.from("profiles")
                .select("id, username, email")
                .eq("id", value: userID.uuidString.lowercased())
                .single()
                .execute().value
            profile = Profile(id: row.id, username: row.username ?? "", email: row.email)
        } catch {
            self.error = "Signed in, but the Blank profile could not be read: \(BlankAccount.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Sign-in was cancelled." }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if text.localizedCaseInsensitiveContains("cancel") { return "Sign-in was cancelled." }
        if text.localizedCaseInsensitiveContains("Signups not allowed") || text.localizedCaseInsensitiveContains("not allowed for otp") {
            return "No Blank account uses this email. Join Blank in the iOS app first."
        }
        return text
    }
}
