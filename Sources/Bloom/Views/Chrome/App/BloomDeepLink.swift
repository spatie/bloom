import AppKit
import Foundation
import BloomCore

/// Preserves Conductor deep links so existing scripts can hand work to Bloom unchanged.
@MainActor
enum BloomDeepLink {
    /// The schemes this copy actually answers to. See `BloomURLScheme` for why it is read off
    /// the bundle.
    static var schemes: Set<String> { BloomURLScheme.own }

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
