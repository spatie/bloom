import Testing
import Foundation
@testable import BloomCore

@Suite("Knowing a row draws nothing before it is drawn")
struct TranscriptRowInkTests {
    private func payload(_ text: String) -> Data { Data(text.utf8) }

    /// The shape 5,573 of the 5,721 system rows in the owner's database have. Every one of them is
    /// a row in the table that draws no view at all.
    @Test("a stream event draws nothing")
    func streamEventIsBlank() {
        let row = payload(#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#)
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: row))
        #expect(TranscriptRowInk.isStreamEvent(kind: .system, payload: row))
    }

    @Test("only a top-level stream event matches the stream prefix")
    func onlyStreamEventsHaveFixedEmptyHeight() {
        let nested = payload(#"{"type":"system","detail":{"type":"stream_event"}}"#)
        let otherKind = payload(#"{"type":"stream_event"}"#)
        #expect(!TranscriptRowInk.isStreamEvent(kind: .system, payload: nested))
        #expect(!TranscriptRowInk.isStreamEvent(kind: .assistantText, payload: otherKind))
    }

    @Test("known silent system events have fixed empty heights")
    func knownSilentSystemEvents() {
        for subtype in ["task_progress", "background_tasks_changed", "vcs_state_changed", "commands_changed"] {
            let row = payload(#"{"type":"system","subtype":"\#(subtype)","x":1}"#)
            #expect(TranscriptRowInk.isDefinitelySilent(kind: .system, payload: row))
        }
        let stream = payload(#"{"type":"stream_event","event":{}}"#)
        #expect(TranscriptRowInk.isDefinitelySilent(kind: .system, payload: stream))
    }

    @Test("visible and nested system events are never fixed empty")
    func visibleEventsRemainMeasurable() {
        for subtype in ["init", "task_notification", "compact_boundary"] {
            let row = payload(#"{"type":"system","subtype":"\#(subtype)"}"#)
            #expect(!TranscriptRowInk.isDefinitelySilent(kind: .system, payload: row))
        }
        let nested = payload(#"{"type":"system","detail":{"subtype":"task_progress"}}"#)
        #expect(!TranscriptRowInk.isDefinitelySilent(kind: .system, payload: nested))
    }

    @Test("session init metadata no longer draws a transcript line")
    func initIsBlank() {
        let row = payload(#"{"type":"system","subtype":"init","cwd":"/tmp","model":"opus"}"#)
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: row))
    }

    /// The other subtypes in the same database: `command`, `hook`, `vcs_`, `code`, `back`.
    @Test("other silent system rows draw nothing, whatever their subtype")
    func otherSubtypesAreBlank() {
        for subtype in ["command", "hook_result", "vcs_status", "code_review", "background"] {
            let row = payload(#"{"type":"system","subtype":"\#(subtype)","x":1}"#)
            #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: row))
        }
    }

    /// **Only `system` is claimed.** Every other kind draws something often enough that a claim
    /// would be a guess, and a wrong guess costs a correction that the mean would not have.
    @Test("no other kind is claimed")
    func onlySystemIsAnswered() {
        let blank = payload(#"{"type":"stream_event"}"#)
        for kind in [MessageKind.user, .assistantText, .thinking, .toolUse, .toolResult,
                     .permissionAsk, .result, .error, .notice] {
            #expect(!TranscriptRowInk.drawsNothing(kind: kind, payload: blank))
        }
    }

    /// The marker is looked for near the front, so a payload that merely mentions the word further
    /// in is not mistaken for an init. A stream event carrying a tool call's arguments can say
    /// anything at all.
    @Test("the marker is only read from the front of the payload")
    func onlyTheFrontIsRead() {
        let tail = String(repeating: " ", count: 400) + #""subtype":"init""#
        let row = payload(#"{"type":"stream_event","text":"\#(tail)"}"#)
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: row))
    }

    /// An empty payload is not an init, and nothing about reading one may crash.
    @Test("an empty payload draws nothing")
    func emptyIsBlank() {
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: Data()))
    }
}
