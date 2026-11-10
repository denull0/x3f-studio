import SwiftUI
import AppKit

/// The "Publish to Blank" window's content: the current request, or a hint when there is none.
struct PublishWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let req = state.publishRequest, state.blankEnabled {
                PublishSheet(request: req, account: state.blank).id(req.id)
            } else {
                Color.clear.frame(width: 620, height: 540)
            }
        }
        // a window restored at launch (or left from a disabled feature) has nothing to show: close it
        .onAppear { if state.publishRequest == nil || !state.blankEnabled { dismiss() } }
    }
}

/// "Publish to Blank": sign in if needed, then the photos in order, a caption, the picture size and
/// optional development notes. Publishing develops, uploads and posts; the result is the post's link.
struct PublishSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var account: BlankAccount
    let request: AppState.PublishRequest
    @StateObject private var publisher = BlankPublisher()
    @State private var photos: [Photo]
    @State private var caption = ""
    @State private var notes = true
    @State private var draft = false
    @State private var email = ""
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    init(request: AppState.PublishRequest, account: BlankAccount) {
        self.request = request
        self.account = account
        _photos = State(initialValue: request.photos)
    }

    private var sizes: [Int] { [1800, 2400, 3000] }
    private func close() { state.publishRequest = nil; dismiss() }
    /// Blank accounts sign in with Apple; the emailed-code path stays available behind a default
    /// (`defaults write com.maybethis.x3fstudio blank.emailSignIn -bool YES`) for projects that allow it.
    private var emailSignIn: Bool { UserDefaults.standard.bool(forKey: "blank.emailSignIn") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if account.isSignedIn { form } else { signIn }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .onChange(of: account.isSignedIn) { _, _ in account.error = nil }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Publish to Blank").font(.headline)
                if let p = account.profile, !p.username.isEmpty {
                    Text("as @\(p.username)" + (Blank.environment == .development ? " · development project" : "")).font(.caption).foregroundStyle(.secondary)
                } else if account.isSignedIn {
                    Text("Signed in — your profile has no username yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("blank.is — no algorithms, no ads, just people sharing things that matter to them").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isSignedIn {
                Button("Sign Out") { Task { await account.signOut() } }.controlSize(.small).disabled(publisher.stage.isBusy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var signIn: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Sign in to your Blank account").font(.title3)
            if account.awaitingBrowser {
                VStack(spacing: 8) {
                    Text("Finish signing in with Apple in your browser, then come back here.").font(.callout)
                    Text("The browser will ask to open X3F Studio; allow it.").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel sign-in") { account.cancelSignIn() }.controlSize(.small)
                }
            } else {
                Button {
                    Task { await account.signInWithApple() }
                } label: {
                    Label("Sign in with Apple", systemImage: "apple.logo").frame(width: 220)
                }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.black)
                .disabled(account.busy)
            }
            if emailSignIn { Text("or with a code sent to the account's email").font(.caption).foregroundStyle(.secondary) }
            if !emailSignIn {
                EmptyView()
            } else if let sent = account.codeSentTo {
                VStack(spacing: 8) {
                    Text("A 6-digit code was sent to \(sent).").font(.callout)
                    HStack {
                        TextField("Code", text: $code).textFieldStyle(.roundedBorder).frame(width: 120).font(.body.monospacedDigit())
                            .onSubmit { Task { await account.verify(code: code) } }
                        Button("Sign In") { Task { await account.verify(code: code) } }.buttonStyle(.borderedProminent).disabled(account.busy || code.count < 6)
                    }
                    Button("Use another email") { account.useAnotherEmail() }.buttonStyle(.link).font(.caption)
                }
            } else {
                HStack {
                    TextField("you@example.com", text: $email).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { Task { await account.sendCode(to: email) } }
                    Button("Send Code") { Task { await account.sendCode(to: email) } }.disabled(account.busy || email.isEmpty)
                }
            }
            if account.busy && !account.awaitingBrowser { ProgressView().controlSize(.small) }
            if let e = account.error { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 420) }
            Spacer()
            Text("Blank accounts sign in with Apple, the same as in the iPhone app. New to Blank? Join there first; publishing needs an account with a username.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.bottom, 8)
        }
        .padding(24)
    }

    private var form: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(photos.count) photo\(photos.count == 1 ? "" : "s") · drag to reorder").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(photos) { photo in
                        HStack(spacing: 8) {
                            FilmstripThumb(photo: photo, current: false, height: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(photo.fileName).font(.caption)
                                Text(photo.camera.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if photos.count > 1 {
                                Button { photos.removeAll { $0.id == photo.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Leave this photo out")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in photos.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
            }
            .frame(width: 260)
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Caption").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $caption).font(.body).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                Toggle("Add development notes (camera, settings) as a text block", isOn: $notes).font(.callout)
                Toggle("Save as a draft on Blank (not shown to others)", isOn: $draft).font(.callout)
                HStack {
                    Text("Picture size").font(.callout)
                    Picker("", selection: $state.blankMaxPixel) {
                        ForEach(sizes, id: \.self) { Text("\($0) px").tag($0) }
                    }.labelsHidden().frame(width: 110)
                    Text("longer side · JPEG 90%").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .done(let ref) = publisher.stage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(ref.url.absoluteString).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.url.absoluteString, forType: .string) }.controlSize(.small)
                        Button("Open") { NSWorkspace.shared.open(ref.url) }.controlSize(.small)
                    }
                    .padding(8).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if publisher.stage.isBusy { ProgressView().controlSize(.small) }
            Text(publisher.stage.text).font(.callout)
                .foregroundStyle({ if case .failed = publisher.stage { return Color.red } else { return Color.secondary } }())
                .lineLimit(2)
            Spacer()
            if case .done = publisher.stage {
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).disabled(publisher.stage.isBusy)
                Button("Publish") {
                    Task { await publisher.publish(photos: photos, caption: caption, notes: notes, draft: draft, maxPixel: state.blankMaxPixel,
                                                   account: account, renders: state.renders, library: state.library) }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(!account.isSignedIn || (account.profile?.username.isEmpty ?? true) || photos.isEmpty || publisher.stage.isBusy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
