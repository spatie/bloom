import AppKit
import Foundation
import BloomCore

/// Preserves Conductor deep links so existing scripts can hand work to Bloom unchanged.
@MainActor
enum BloomDeepLink {
    /// The schemes this copy actually answers to, read off its own bundle rather than written out.
    ///
    /// It was the literal `"bloom"`, and `Tools/dev-build.sh` rebrands the registered scheme to
    /// `bloomdev` so the dev copy cannot swallow a link meant for the real one. The result was a
    /// dev build that registered `bloomdev://`, received them, and then refused every one with
    /// "The link must include a prompt and project path", which is not what was wrong with it.
    /// Reading `CFBundleURLTypes` means the check can only ever disagree with LaunchServices if
    /// the plist does.
    static let schemes: Set<String> = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let registered = (types ?? [])
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { $0.lowercased() }

        // A bundle with no URL types is `swift run` or a test host. Falling back to the shipped
        // scheme keeps those working rather than making every link fail in a way that reads as a
        // malformed link.
        return registered.isEmpty ? ["bloom"] : Set(registered)
    }()

    static func open(_ url: URL, in app: AppModel) async {
        let request: BloomLinkRequest
        do {
            request = try BloomLinkRequest(url: url, schemes: schemes)
        } catch {
            app.alert = BloomAlert(title: "Could not open the Bloom link", message: error.localizedDescription)
            return
        }
        switch request {
        case .workspace(let id, let chatID):
            await app.open(workspaceID: id, chatID: chatID)

        case .prompt(let prompt, let path):
            // The same answer workspace_start gives to "which project is this path".
            guard let repo = BridgeProjectLookup.project(atPath: path, in: app.repos) else {
                app.alert = BloomAlert(
                    title: "Project not found",
                    message: "The path in this link is not one of Bloom's projects: \(path)"
                )
                return
            }
            await app.createWorkspace(in: repo, prompt: prompt)
        }
    }
}
