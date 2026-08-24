import Testing
@testable import BloomCore

@Suite("Pane glyphs")
struct PaneGlyphTests {
    @Test("A chat wears the chat glyph in a workspace on one backend")
    func chatWearsTheBubble() {
        let kinds: [AgentKind] = [.claudeCode, .claudeCode, .claudeCode]
        let mark = PaneGlyph.agentMark(for: .claudeCode, among: kinds)
        #expect(mark == nil)
        #expect(PaneGlyph.chatTab(agentMark: mark) == PaneGlyph.chat)
    }

    /// The slot says the more specific thing when there is one to say. Every tab in the row is a
    /// chat, so the bubble is what it can afford to give up.
    @Test("A chat wears its backend's mark in a workspace running two")
    func chatWearsTheAgentMark() {
        let kinds: [AgentKind] = [.claudeCode, .codex]
        #expect(PaneGlyph.chatTab(agentMark: PaneGlyph.agentMark(for: .codex, among: kinds))
            == PaneGlyph.agentMark(for: .codex))
        #expect(PaneGlyph.chatTab(agentMark: PaneGlyph.agentMark(for: .claudeCode, among: kinds))
            == PaneGlyph.agentMark(for: .claudeCode))
    }

    @Test("One backend needs no marking, two do")
    func marksOnlyWhenMixed() {
        #expect(!PaneGlyph.marksAgents([AgentKind.claudeCode]))
        #expect(!PaneGlyph.marksAgents([AgentKind.codex, .codex, .codex]))
        #expect(PaneGlyph.marksAgents([AgentKind.claudeCode, .codex]))
    }

    @Test("An empty workspace needs no marking")
    func emptyNeedsNoMark() {
        #expect(!PaneGlyph.marksAgents([AgentKind]()))
        #expect(PaneGlyph.agentMark(for: .claudeCode, among: [AgentKind]()) == nil)
    }

    /// Every kind in the strip has one now, and no two of them are the same mark.
    @Test("The strip's glyphs are distinct")
    func glyphsAreDistinct() {
        let strip = [
            PaneGlyph.chat, PaneGlyph.terminal, PaneGlyph.browser,
            PaneGlyph.review, PaneGlyph.notes,
        ]
        #expect(Set(strip).count == strip.count)
    }
}
