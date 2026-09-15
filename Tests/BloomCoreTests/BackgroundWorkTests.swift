import Testing
import Foundation
@testable import BloomCore

/// The sentence under a finished turn naming what the agent left running. See `BackgroundWork`.
@Suite struct BackgroundWorkTests {
    private func command(_ description: String, state: SubagentState = .running) -> Subagent {
        Subagent(
            id: SubagentID(UUID().uuidString), description: description,
            taskType: "local_bash", state: state
        )
    }

    private func agent(_ description: String) -> Subagent {
        Subagent(id: SubagentID(UUID().uuidString), description: description, taskType: "local_agent")
    }

    @Test func nothingRunningSaysNothing() {
        #expect(BackgroundWork.note(for: SubagentRoster()) == nil)
        #expect(BackgroundWork.note(for: [command("Done already", state: .completed)]) == nil)
    }

    /// The case the screenshot was of.
    @Test func oneCommandIsNamed() {
        let note = BackgroundWork.note(for: [command("Wait for the PR's Test run to finish")])
        #expect(note == "A background command is still running: Wait for the PR's Test run to finish.")
    }

    @Test func finishedOnesAreLeftOut() {
        let note = BackgroundWork.note(for: [
            command("Wait for main head's Test run to finish", state: .completed),
            command("Wait for the PR's Test run to finish"),
        ])
        #expect(note == "A background command is still running: Wait for the PR's Test run to finish.")
    }

    @Test func severalOfOneKindAreCountedAndNamed() {
        let note = BackgroundWork.note(for: [command("Build"), command("Test")])
        #expect(note == "2 background commands are still running: Build and Test.")
    }

    @Test func aSubagentTakesAnArticleThatReads() {
        #expect(BackgroundWork.note(for: [agent("Audit the parser")])
            == "A subagent is still running: Audit the parser.")
    }

    @Test func mixedKindsShareOneNoun() {
        let note = BackgroundWork.note(for: [command("Build"), agent("Audit the parser")])
        #expect(note == "2 background tasks are still running: Build and Audit the parser.")
    }

    @Test func aLongListIsCut() {
        let note = BackgroundWork.note(for: ["A", "B", "C", "D", "E"].map { command($0) })
        #expect(note == "5 background commands are still running: A, B, C and 2 more.")
    }

    @Test func anArchiveThatStoppedNothingSaysNothing() {
        #expect(BackgroundWork.archived("Docs", stopping: []) == nil)
    }

    @Test func anArchiveNamesTheCommandsItStopped() {
        #expect(BackgroundWork.archived("Docs", stopping: [command("Serve the app")])
            == "Docs was archived. It stopped a background command: Serve the app.")
        #expect(BackgroundWork.archived("Docs", stopping: [command("Serve the app"), command("Serve docs")])
            == "Docs was archived. It stopped 2 background commands: Serve the app and Serve docs.")
    }

    /// The notice draws its first sentence large and the rest small, so the split has to land
    /// between the archive and what it stopped.
    @Test func theArchiveNoticeSplitsAfterTheFact() throws {
        let message = try #require(BackgroundWork.archived("Docs", stopping: [command("Serve on 127.0.0.1:8018")]))
        let text = NoticeText(message)
        #expect(text.fact.map(\.text).joined() == "Docs was archived.")
        #expect(text.reason.map(\.text).joined() == "It stopped a background command: Serve on 127.0.0.1:8018.")
    }
}
