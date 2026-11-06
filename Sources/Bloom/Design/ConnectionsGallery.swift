import SwiftUI
import BloomCore

/// Settings > GitHub & GitLab on a Mac with neither CLI, and on one signed in to both, with
/// accounts made up so a capture shows nobody's.
///
///     Bloom --snapshot-gallery /tmp/shots --gallery connections
extension Gallery {
    static let connections = Gallery(
        name: "connections",
        title: "GitHub & GitLab settings",
        size: CGSize(width: 1260, height: 420),
        needsFocus: false,
        view: { _ in
            AnyView(HStack(alignment: .top, spacing: 20) {
                ConnectionsForm(
                    gitHub: .notInstalled, gitHubUser: nil, gitLabInstalled: false, gitLabAccounts: [:]
                ) { _ in }
                ConnectionsForm(
                    gitHub: .ready, gitHubUser: "octocat", gitLabInstalled: true,
                    gitLabAccounts: ["gitlab.com": "octocat", "gitlab.example.com": "octocat"]
                ) { _ in }
            })
        }
    )
}
