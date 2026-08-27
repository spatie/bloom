import Testing
import Foundation
@testable import BloomCore

@Suite("How a turn ended, as the footer says it")
struct TurnEndingTests {
    @Test("a clean turn is a finish")
    func cleanFinish() {
        #expect(TurnEnding.of(wasStopped: false, succeeded: true, denials: 0) == .finished)
        #expect(TurnEnding.of(wasStopped: false, succeeded: true, denials: 0).note(permissionMode: .auto, agentKind: .claudeCode) == nil)
    }

    @Test("a stop is named before the error the stop caused")
    func stopBeatsTheErrorItCauses() {
        // The owner's bug. SIGTERM makes the CLI report `error_during_execution` on its way out,
        // so a stopped turn arrives carrying an error result and used to be drawn as a failure:
        // the same red cross a crash gets, with nothing saying a button had been pressed.
        #expect(TurnEnding.of(wasStopped: true, succeeded: false, denials: 0) == .stopped)
        #expect(TurnEnding.of(wasStopped: true, succeeded: true, denials: 3) == .stopped)
    }

    @Test("a turn that was not stopped and did not succeed is still a failure")
    func failureIsStillAFailure() {
        #expect(TurnEnding.of(wasStopped: false, succeeded: false, denials: 0) == .failed)
        // Its own row already says what went wrong, at length, so the footer adds nothing.
        #expect(TurnEnding.of(wasStopped: false, succeeded: false, denials: 0).note(permissionMode: .auto, agentKind: .claudeCode) == nil)
    }

    @Test("declined calls are still reported on a turn that otherwise succeeded")
    func denialsSurvive() {
        #expect(TurnEnding.of(wasStopped: false, succeeded: true, denials: 2) == .denied(2))
    }

    @Test("a stopped turn says so, in words, and says the work is safe")
    func stopSpeaks() {
        let note = TurnEnding.stopped.note(permissionMode: .auto, agentKind: .claudeCode)
        #expect(note?.contains("You stopped this turn") == true)
        // The question somebody actually has the moment after pressing Stop.
        #expect(note?.contains("worktree") == true)
        #expect(TurnEnding.stopped.label == "Stopped")
    }

    @Test("the sentence about declined calls names the setting that declined them")
    func denialsNameTheMode() {
        let note = TurnEnding.denied(1).note(permissionMode: .acceptEdits, agentKind: .claudeCode)
        #expect(note?.contains("1 tool call was") == true)
        #expect(note?.contains(PermissionMode.acceptEdits.label(on: .claudeCode)) == true)
        #expect(TurnEnding.denied(4).note(permissionMode: .auto, agentKind: .claudeCode)?.contains("4 tool calls were") == true)
    }
}

@Suite("Which turn a stop belongs to")
struct StoppedTurnTests {
    @Test("the row that closed the last turn")
    func lastResult() {
        let kinds: [MessageKind] = [.user, .assistantText, .result, .user, .toolUse, .result]
        #expect(StoppedTurn.closingRow(in: kinds) == 5)
    }

    @Test("nothing, when the stopped turn never wrote a result")
    func killedBeforeItSaidAnything() {
        // SIGKILL, or a CLI that says nothing on its way out. The last result in the list closed
        // an earlier turn, which finished perfectly well, and marking that one stopped would put a
        // sentence about a button under a turn nobody touched.
        let kinds: [MessageKind] = [.user, .assistantText, .result, .user, .toolUse]
        #expect(StoppedTurn.closingRow(in: kinds) == nil)
    }

    @Test("nothing at all in an empty transcript, and nothing in one with no turns")
    func nothingToName() {
        #expect(StoppedTurn.closingRow(in: [MessageKind]()) == nil)
        #expect(StoppedTurn.closingRow(in: [.system, .notice]) == nil)
    }

    @Test("reads the same answer off a lazily mapped list, which is how the transcript asks")
    func lazyIsTheSame() {
        // The transcript hands this `rows.lazy.map(\.kind)` so a session of thousands of rows is
        // not copied to answer a question the last two settle.
        let kinds: [MessageKind] = [.user, .result, .permissionAsk]
        #expect(StoppedTurn.closingRow(in: kinds.lazy.map { $0 }) == 1)
    }
}
