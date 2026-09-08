import Testing
import Foundation
@testable import BloomCore

@Suite struct BackendChangeTests {
    /// The rule, and the reason for it: a chat's rows, its thread id and its context all belong to
    /// the backend that made them.
    @Test func aChatThatHasSpokenForksRatherThanChanging() {
        #expect(BackendChange.decide(from: .claudeCode, to: .codex, hasSpoken: true) == .fork(.codex))
        #expect(BackendChange.decide(from: .codex, to: .claudeCode, hasSpoken: true) == .fork(.claudeCode))
    }

    @Test func anEmptyChatSimplyChanges() {
        #expect(BackendChange.decide(from: .claudeCode, to: .codex, hasSpoken: false)
            == .changeInPlace(.codex))
    }

    /// Pressing the entry a chat is already on must not make a second chat.
    @Test func choosingTheBackendItIsAlreadyOnDoesNothing() {
        #expect(BackendChange.decide(from: .codex, to: .codex, hasSpoken: true) == .unchanged)
        #expect(BackendChange.decide(from: .codex, to: .codex, hasSpoken: false) == .unchanged)
    }

    /// A stale menu or a deep link cannot put a chat on a backend with no runner.
    @Test func aBackendWithNoRunnerIsNotADestination() {
        #expect(BackendChange.decide(from: .claudeCode, to: .cursor, hasSpoken: false) == .unchanged)
        #expect(BackendChange.decide(from: .claudeCode, to: .openCode, hasSpoken: true) == .unchanged)
    }

    /// The reported bug, from the side the core can hold: an older chat whose transcript has not
    /// finished reading is not an empty chat, and reading it as one changed it in place and left a
    /// Claude Code thread id on a row Codex was about to resume from.
    @Test func aChatWhoseHistoryHasNotBeenReadCountsAsHavingSpoken() {
        #expect(BackendChange.hasSpoken(rowCount: 0, agentSessionID: nil, isTranscriptLoaded: false))
        #expect(BackendChange.decide(
            from: .claudeCode,
            to: .codex,
            hasSpoken: BackendChange.hasSpoken(
                rowCount: 0, agentSessionID: nil, isTranscriptLoaded: false
            )
        ) == .fork(.codex))
    }

    /// A thread id is proof on its own, and it needs no read: it is a column on the row. This is
    /// the state a chat is in for the whole of its first turn, before any row has been written.
    @Test func aThreadIdIsProofOnItsOwn() {
        #expect(BackendChange.hasSpoken(
            rowCount: 0, agentSessionID: "abc-123", isTranscriptLoaded: true
        ))
        // An empty string is not an id. A column written blank must not fork a chat that never ran.
        #expect(!BackendChange.hasSpoken(rowCount: 0, agentSessionID: "", isTranscriptLoaded: true))
    }

    @Test func aRowOnScreenIsProofOnItsOwn() {
        #expect(BackendChange.hasSpoken(rowCount: 3, agentSessionID: nil, isTranscriptLoaded: true))
    }

    /// The only combination that may answer no, so a genuinely new chat still changes in place
    /// rather than making a second tab nobody asked for.
    @Test func aReadAndEmptyChatHasNotSpoken() {
        #expect(!BackendChange.hasSpoken(rowCount: 0, agentSessionID: nil, isTranscriptLoaded: true))
        #expect(BackendChange.decide(
            from: .claudeCode,
            to: .codex,
            hasSpoken: BackendChange.hasSpoken(
                rowCount: 0, agentSessionID: nil, isTranscriptLoaded: true
            )
        ) == .changeInPlace(.codex))
    }

    /// A fork nobody is shown is indistinguishable from a picker that does nothing, which is what
    /// was reported. The sentence has to name the chat that was made and the backend that stayed.
    @Test func theForkNoticeNamesTheNewChatAndTheBackendThatStayed() {
        let message = BackendChange.forkNotice(title: "Fix the parser on Codex", from: .claudeCode)
        let text = NoticeText(message)
        #expect(text.plain.contains("Fix the parser on Codex"))
        #expect(text.plain.contains("Claude Code"))
        // Two sentences: what happened, then why. The title is a machine's word, so it is marked.
        #expect(!text.reason.isEmpty)
        #expect(text.fact.contains { $0.isMachine && $0.text == "Fix the parser on Codex" })
    }

    /// Ask Bloom has no second tab, so its fork archives and replaces. That is a bigger surprise
    /// than a new tab and the sentence has to say the old conversation is still there.
    @Test func theReplacementNoticeSaysNothingIsLost() {
        let text = NoticeText(BackendChange.replacementNotice(from: .claudeCode, to: .codex))
        #expect(text.plain.contains("Codex"))
        #expect(text.plain.contains("Claude Code"))
        #expect(text.plain.contains("archived"))
        #expect(!text.reason.isEmpty)
    }

    @Test func aForkThatCouldNotBeMadeSaysSoRatherThanNothing() {
        let text = NoticeText(BackendChange.forkFailureNotice(to: .codex))
        #expect(text.plain.contains("Codex"))
        #expect(text.plain.contains("unchanged"))
    }

    @Test func aForkIsNamedSoTheStripCanTellThemApart() {
        #expect(BackendChange.forkedTitle("Fix the parser", to: .codex) == "Fix the parser on Codex")
        #expect(BackendChange.forkedTitle("", to: .codex) == "New session on Codex")
        // Forking twice must not accumulate.
        #expect(BackendChange.forkedTitle("Fix the parser on Codex", to: .claudeCode)
            == "Fix the parser on Claude Code")
    }
}
