import Foundation
import SessionCore

/// What the app is asked to open from outside: a `.rdp` file from Files or
/// Mail, an `rdp://` link, or `mremote://connect?profile=…` from the
/// Shortcuts app.
///
/// A saved connection is opened straight away. Anything new goes to the
/// editor first: a link or a file is something anyone can send, so it never
/// connects to a host the user has not saved.
extension AppEnvironment {
    func open(_ url: URL) async {
        // A cold launch delivers the URL before the profiles are read.
        for _ in 0..<100 where repository == nil && loadFailure == nil {
            try? await Task.sleep(for: .milliseconds(30))
        }
        if url.isFileURL {
            await openFile(url)
        } else if url.scheme?.lowercased() == "rdp", let file = RDPFile(url: url) {
            await open(file, name: nil)
        } else if url.scheme?.lowercased() == "mremote", url.host() == "connect",
                  let profile = profile(named: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "profile" }?.value) {
            await openSaved(profile)
        }
    }

    /// By its identifier or, failing that, its name.
    func profile(named reference: String?) -> ConnectionProfile? {
        guard let reference else { return nil }
        if let uuid = UUID(uuidString: reference), let match = profiles.first(where: { $0.id.rawValue == uuid }) {
            return match
        }
        return profiles.first { $0.displayName == reference }
    }

    func openSaved(_ profile: ConnectionProfile) async {
        if let running = runningSession(for: profile) {
            present(running)
        } else {
            await connect(to: profile)
        }
    }

    private func openFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let file = RDPFile(data: data) else {
            importFailure = String(localized: "\(url.lastPathComponent) は接続先として読めませんでした。")
            return
        }
        await open(file, name: url.deletingPathExtension().lastPathComponent)
    }

    private func open(_ file: RDPFile, name: String?) async {
        guard let imported = file.profile(named: name) else { return }
        if let saved = profiles.first(where: { $0.matches(imported) }) {
            await openSaved(saved)
            return
        }
        presentedSession = nil
        pendingImport = ProfileEditorModel(mode: .importing(imported, unsupported: file.unsupportedSettings))
    }
}

private extension ConnectionProfile {
    /// The same computer, as the same user when the other names one.
    func matches(_ other: ConnectionProfile) -> Bool {
        endpoint.host.caseInsensitiveCompare(other.endpoint.host) == .orderedSame
            && endpoint.port == other.endpoint.port
            && (other.account.username == nil || other.account.username == account.username)
    }
}
