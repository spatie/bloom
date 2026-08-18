import Foundation

/// A file a turn touched, with the line counts taken from the tool calls themselves.
struct TurnFile: Identifiable, Hashable, Sendable {
    var path: String
    var additions: Int
    var deletions: Int

    var id: String { path }
    var name: String { ToolPresenter.basename(path) }
}
