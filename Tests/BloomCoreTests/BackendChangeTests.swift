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

    @Test func aForkIsNamedSoTheStripCanTellThemApart() {
        #expect(BackendChange.forkedTitle("Fix the parser", to: .codex) == "Fix the parser on Codex")
        #expect(BackendChange.forkedTitle("", to: .codex) == "New session on Codex")
        // Forking twice must not accumulate.
        #expect(BackendChange.forkedTitle("Fix the parser on Codex", to: .claudeCode)
            == "Fix the parser on Claude Code")
    }
}
