/// The mark on a tab that says what is in it.
///
/// Terminal wore one, browser wore one, chat wore nothing, which was a deliberate decision and
/// the wrong one: a strip reading `Chat | Browser | Terminal` with a glyph on two of the three
/// reads as a row that has lost an icon rather than as a row that never had one. The argument for
/// leaving chats bare was that a strip is mostly chats and a glyph on every tab is noise, and it
/// holds right up until the strip is mixed, which is the only strip anybody actually looks at.
///
/// It is in the core because two of the three answers here are decisions rather than constants:
/// which mark a chat carries in a workspace running more than one backend, and whether such a
/// workspace needs marking at all.
///
/// **These are SF Symbol names and nothing else.** No frameworks, no images, no sizes. The core
/// draws nothing; what it settles is which of them a tab is entitled to, which is a question with
/// cases and therefore a question a test should be able to ask.
public enum PaneGlyph {
    /// A speech bubble with lines in it.
    ///
    /// Weight is the whole of the choice, and it was made against the two glyphs that were
    /// already there rather than in a gallery at eight times. `apple.terminal` and `globe` are
    /// both closed outlines with internal detail, a prompt and a set of meridians, drawn at about
    /// eleven points. A bare `bubble.left` is an empty rounded shape and next to those two it
    /// reads as a blank, and `bubble.left.and.bubble.right`, which the `+` menu used to offer,
    /// puts two overlapping outlines in the same eleven points and comes out as a smudge. The
    /// lines inside this one are the same kind of internal detail at the same weight as the other
    /// two, so the three sit on one line without any of them being the loud one.
    public static let chat = "text.bubble"
    public static let terminal = "apple.terminal"
    public static let browser = "globe"
    public static let review = "doc.text"
    public static let notes = "note.text"

    /// What one chat tab wears.
    ///
    /// The agent mark where there is one, and the chat bubble everywhere else. A workspace whose
    /// chats are not all on the same backend has something more specific to say in that slot than
    /// "this is a chat", and every tab in the row is a chat anyway, so the bubble is what it can
    /// afford to give up. The slot is one glyph wide and stays one glyph wide, so nothing in the
    /// strip moves as a second backend arrives.
    public static func chatTab(agentMark: String?) -> String {
        agentMark ?? chat
    }

    // MARK: - Which agent, when it matters

    /// Whether these chats need marking by backend at all.
    ///
    /// Takes the whole set rather than one session, because that is the question: a mark on a tab
    /// is meaningless without the tabs beside it. Five Claude Code chats get no marks, because
    /// there is nothing there to tell apart.
    public static func marksAgents(_ kinds: some Sequence<AgentKind>) -> Bool {
        Set(kinds).count > 1
    }

    /// The glyph for one backend, or nil when nothing in this workspace needs marking.
    ///
    /// Both are marked when either is. Marking only the unfamiliar one would leave the other
    /// reading as "no agent" rather than as the agent everything else here is on.
    public static func agentMark(for kind: AgentKind, among kinds: some Sequence<AgentKind>) -> String? {
        guard marksAgents(kinds) else { return nil }
        return agentMark(for: kind)
    }

    public static func agentMark(for kind: AgentKind) -> String {
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
