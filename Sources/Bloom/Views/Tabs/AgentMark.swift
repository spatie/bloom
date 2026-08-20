import SwiftUI
import BloomCore

/// The small mark that says which agent a chat is on.
///
/// A tab strip of conversations deliberately carries no icons: that is what keeps it from reading
/// as a toolbar. But with two backends you would have to open a chat to find out what is running
/// it, and the answer changes what the composer offers, what a permission question means and what
/// the numbers in the inspector stand for.
///
/// So the mark appears **only where it is telling you something**: in a workspace whose chats are
/// not all on the same backend. Five Claude Code chats get no marks, because there is nothing
/// there to tell apart, and the strip stays what it was.
enum AgentMark {
    /// Whether these chats need marking at all.
    ///
    /// Takes the whole set rather than one session, because that is the question: a mark on a tab
    /// is meaningless without the tabs beside it.
    static func marks(_ sessions: [Session]) -> Bool {
        Set(sessions.map(\.agentKind)).count > 1
    }

    /// The glyph for one backend, or nil when nothing needs marking.
    ///
    /// Both are marked when either is. Marking only the unfamiliar one would leave the other
    /// reading as "no agent" rather than as the agent everything else here is on.
    static func glyph(for kind: AgentKind, in sessions: [Session]) -> String? {
        guard marks(sessions) else { return nil }
        return glyph(for: kind)
    }

    static func glyph(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: "asterisk"
        case .codex: "circle.hexagongrid"
        // Neither can run a chat, so neither can be on a tab. Named anyway rather than defaulted,
        // so adding a third backend is a compiler error here instead of a wrong glyph.
        case .cursor: "cursorarrow"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }
}
