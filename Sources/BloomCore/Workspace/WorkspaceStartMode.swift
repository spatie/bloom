import Foundation
import BloomClient

public typealias WorkspaceStartMode = BloomClient.WorkspaceStartMode

extension WorkspaceStartMode {
    /// The pane this mode opens the workspace on.
    ///
    /// The mapping is here rather than in the centre column because it is the only place the two
    /// lists meet, and because a fourth kind added to either one has to be answered for rather
    /// than fall through a `default` in a view. See `NewPane`, which is what makes the pane.
    public var pane: PaneKind {
        switch self {
        case .chat: .chat
        case .terminal: .terminal
        case .browser: .browser
        }
    }

}
