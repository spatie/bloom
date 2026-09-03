import Foundation
import Testing
@testable import BloomCore

/// What a runner does when the store refuses a write.
///
/// This was two copies of one rule, one per backend, and neither was reachable without driving a
/// fake process through a whole turn. The rule is four sentences long and every one of them is
/// asserted here.
@Suite("Persistence trouble")
struct PersistenceTroubleTests {
    private static func complaint(_ standing: TranscriptStanding) -> WorkspaceTrouble? {
        WorkspaceTrouble.recording(transcript: standing, complaint: "FOREIGN KEY constraint failed")
    }

    /// A database that has genuinely gone wrong is said out loud, and the sentence stays readable
    /// on the runner afterwards. These used to be `try?`, and a failing database threw a whole
    /// transcript away and told nobody.
    @Test("a refusal from a session that is still there is reported and counted")
    func reportsARealFailure() {
        var trouble = PersistenceTrouble()

        let outcome = trouble.record(Self.complaint(.there))

        guard case .tell(let sentence) = outcome else {
            Issue.record("a live transcript's refusal has to be told: \(outcome)")
            return
        }
        #expect(sentence.contains("FOREIGN KEY constraint failed"))
        #expect(trouble.failures == 1)
        #expect(trouble.lastSentence == sentence)
        #expect(!trouble.hasStopped)
    }

    /// A database that cannot answer whether the row exists is broken by any reading, so it
    /// reports rather than guessing in the quiet direction.
    @Test("a store that cannot say whether the transcript is there still reports")
    func reportsAnUnanswerableStore() {
        var trouble = PersistenceTrouble()

        // Lifted out of `#expect`, which rewrites its argument into a closure taking the value
        // immutably. See the note in CLAUDE.md.
        let outcome = trouble.record(Self.complaint(.unanswerable))

        #expect(outcome != .stop)
        #expect(trouble.failures == 1)
        #expect(!trouble.hasStopped)
    }

    /// Archiving a workspace under a turn that is still in flight takes the session row with it,
    /// and the foreign key then correctly refuses the next row the turn writes. Nothing is wrong,
    /// so nothing is said, and the run is stopped because an agent working in a worktree nobody is
    /// recording is the part that would be a fault.
    @Test("a transcript that has gone stops the run without a word")
    func stopsWhenTheTranscriptHasGone() {
        var trouble = PersistenceTrouble()

        let outcome = trouble.record(Self.complaint(.gone))

        #expect(outcome == .stop)
        #expect(trouble.hasStopped)
        // Silently: nothing was counted and nothing is left for a window to draw.
        #expect(trouble.failures == 0)
        #expect(trouble.lastSentence == nil)
    }

    /// Everything already in flight when the rows went is refused the same way on its way through:
    /// the turn's remaining lines, the session save that stopping provokes, and any question still
    /// open. One stop covers all of them, and a second would arrive while the first was still
    /// being carried out.
    @Test("the second refusal after the transcript went stops nothing")
    func stopsOnlyOnce() {
        var trouble = PersistenceTrouble()

        let first = trouble.record(Self.complaint(.gone))
        let second = trouble.record(Self.complaint(.gone))
        let third = trouble.record(Self.complaint(.gone))

        #expect(first == .stop)
        #expect(second == .alreadyStopped)
        #expect(third == .alreadyStopped)
        #expect(trouble.failures == 0)
    }

    /// The two are told apart by asking the store which one it is, not by reading SQLite's
    /// message, which says the same thing for both. A run that has been stopped can still have
    /// been reporting real failures before it.
    @Test("failures before the transcript went are kept, and the stop does not clear them")
    func keepsWhatWasReportedBeforeTheStop() {
        var trouble = PersistenceTrouble()

        _ = trouble.record(Self.complaint(.there))
        _ = trouble.record(Self.complaint(.there))
        #expect(trouble.failures == 2)

        let stopped = trouble.record(Self.complaint(.gone))

        #expect(stopped == .stop)
        #expect(trouble.failures == 2)
        #expect(trouble.lastSentence != nil)
    }
}
