import Foundation

/// What a drag let go over one of the centre column's panes turns out to have been.
///
/// Two things can be dropped on a pane and they mean different things. A tab dragged out of the
/// strip is content arriving: the pane shows it, or a new pane opens beside this one holding it. A
/// pane of the tab already in front is an arrangement being changed: nothing arrives, nothing
/// leaves, and the same pane id ends up somewhere else in the tree.
///
/// They cannot be told apart by the id alone, which is the whole reason this exists. A tab nobody
/// has split is one pane carrying the id of the content at its root, and splitting it leaves that
/// pane carrying it still, so **one string is both a tab id and a pane id at the same time**.
/// Reading a drop as the wrong one of the two would either replace a pane with the tab it already
/// belongs to, or rearrange a tree because somebody dragged a tab onto it.
///
/// So a pane says so and a tab does not. The bare id stays what it has always been, because it is
/// what the strip has been sending since tabs could be dragged at all and what the sidebar's rows
/// send too, and because anything else let go over a pane, a line of text out of another app
/// included, arrives as a bare string and has to keep failing the membership check rather than
/// being read as a rearrangement. A pane carries a prefix no tab id can have, since every id this
/// app writes is a lowercased UUID.
public enum PaneDrop: Equatable, Sendable {
    /// A tab from the strip, or something that is not one at all, which the caller finds out by
    /// looking the id up in the workspace.
    case tab(String)
    /// A pane of the tab in front, on its way somewhere else in the same tree.
    case pane(String)

    private static let paneMark = "bloom.pane:"

    public var encoded: String {
        switch self {
        case .tab(let id): id
        case .pane(let id): Self.paneMark + id
        }
    }

    public init(encoded: String) {
        if encoded.hasPrefix(Self.paneMark) {
            self = .pane(String(encoded.dropFirst(Self.paneMark.count)))
        } else {
            self = .tab(encoded)
        }
    }

    /// The pane this drop is moving, if it is moving one.
    public var movedPane: String? {
        guard case .pane(let id) = self else { return nil }
        return id
    }
}
