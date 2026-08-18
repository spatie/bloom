import Foundation

/// A `/command` the user can run.
///
/// Baton ships no list of its own. The commands that exist are whatever markdown files sit in the
/// user's and the repository's `.claude/commands` folders, and those change while the app is
/// running without anything telling us, so they are read from disk rather than modelled.
struct SlashCommand: Identifiable, Hashable, Sendable {
    enum Origin: String, Sendable {
        case project
        case user

        var label: String {
            switch self {
            case .project: "project"
            case .user: "user"
            }
        }
    }

    var name: String
    var detail: String
    var origin: Origin

    var id: String { "\(origin.rawValue):\(name)" }
}
