import Testing
import Foundation
@testable import BloomCore

// MARK: - Telling an agent from a background command

/// **Bloom had been putting two different things in one list.**
///
/// `system/task_started` is sent for a Task subagent and for a backgrounded Bash command alike,
/// and `task_type` is the only field that separates them. The values below are taken from the
/// transcripts on the machine this was written on: 13 lines saying `local_agent` and 65 saying
/// `local_bash`, so the case nothing was written for was the common one.
///
/// The shapes are quoted verbatim from those captures, minus the uuids.
@Suite struct SubagentKindTests {
    /// A `local_agent` start. Everything an agent's pane wants is on it.
    static let agentLine = """
    {"type":"system","subtype":"task_started","task_id":"ae8b434e1a270eeac",\
    "tool_use_id":"toolu_01Y1","description":"Count lines in a.txt",\
    "subagent_type":"general-purpose","is_backgrounded":false,"spawn_depth":1,\
    "task_type":"local_agent","prompt":"Read the file a.txt and report its line count."}
    """

    /// A `local_bash` start, whole. Four fields and no more: no `subagent_type`, no `spawn_depth`,
    /// no `is_backgrounded` and **no prompt**. This is the line that made a background command
    /// describe itself as a subagent with nothing to say.
    static let commandLine = """
    {"type":"system","subtype":"task_started","task_id":"bpx5joeoj",\
    "tool_use_id":"toolu_01KuPv","description":"Commit composer.json metadata change",\
    "task_type":"local_bash"}
    """

    private func subagent(_ line: String) throws -> Subagent {
        let json = try #require(JSONValue.parse(line))
        let signal = try #require(SubagentSignal.decode(json))
        var roster = SubagentRoster()
        roster.apply(signal)
        return try #require(roster.subagents.first)
    }

    @Test func aTaskSubagentIsAnAgent() throws {
        let agent = try subagent(Self.agentLine)
        #expect(agent.taskType == "local_agent")
        #expect(agent.kind == .agent)
        #expect(agent.kind.writesTranscript)
    }

    @Test func aBackgroundedShellCommandIsNotAnAgent() throws {
        let command = try subagent(Self.commandLine)
        #expect(command.taskType == "local_bash")
        #expect(command.kind == .command)
        #expect(!command.kind.writesTranscript)
    }

    /// The evidence for the bug, kept as a test so it cannot come back: the command line carries
    /// none of the fields the pane was reading.
    @Test func aBackgroundCommandCarriesNoneOfAnAgentsFields() throws {
        let command = try subagent(Self.commandLine)
        #expect(command.prompt.isEmpty)
        #expect(command.type.isEmpty)
        #expect(!command.description.isEmpty)
    }

    /// A `task_type` nobody has seen is an agent, not a command. An agent's pane degrades to a
    /// title and a summary when a field is missing; a command's pane would claim a command line
    /// that does not exist.
    @Test func anUnknownTaskTypeIsTreatedAsAnAgent() {
        #expect(SubagentKind(taskType: "") == .agent)
        #expect(SubagentKind(taskType: "remote_agent") == .agent)
        #expect(SubagentKind(taskType: "local_bash_v2") == .agent)
        #expect(SubagentKind(taskType: "local_bash") == .command)
    }
}

// MARK: - What the pane says

@Suite struct SubagentPaneTests {
    private func agent(
        type: String = "Explore", depth: Int = 1, seconds: Int = 0, state: SubagentState = .running
    ) -> Subagent {
        Subagent(id: SubagentID("a"), description: "Find the call sites", type: type,
                 spawnDepth: depth, prompt: "Find every call site.", taskType: "local_agent",
                 state: state, elapsedSeconds: seconds)
    }

    private func command(seconds: Int = 0) -> Subagent {
        Subagent(id: SubagentID("b"), description: "Build frontend assets",
                 taskType: "local_bash", elapsedSeconds: seconds)
    }

    /// The literal word in Freek's screenshot. It was the fallback for an absent `subagent_type`,
    /// which a background command never has, so every background command said it.
    @Test func aBackgroundCommandNoLongerCallsItselfASubagent() {
        let subtitle = SubagentPane.subtitle(command(seconds: 12))
        #expect(subtitle == "background command . 12s")
        #expect(!subtitle.contains("subagent"))
    }

    @Test func anAgentLeadsWithItsType() {
        #expect(SubagentPane.subtitle(agent(seconds: 5)) == "Explore . 5s")
    }

    /// Depth is the one thing the pane can say that the sidebar cannot, since every depth is drawn
    /// at the same indent there. And only past one, which is otherwise noise on every row.
    @Test func depthIsSaidOnlyWhenItIsPastOne() {
        #expect(!SubagentPane.subtitle(agent(depth: 1)).contains("depth"))
        #expect(SubagentPane.subtitle(agent(depth: 3)).contains("depth 3"))
    }

    /// An agent with no type at all still gets a noun rather than an empty first field.
    @Test func anAgentWithNoTypeFallsBackToTheNoun() {
        #expect(SubagentPane.subtitle(agent(type: "")).hasPrefix("subagent"))
    }

    @Test func theHeadingsMatchWhatTheThingActuallyIs() {
        #expect(SubagentPane.briefLabel(.agent) == "Asked")
        #expect(SubagentPane.briefLabel(.command) == "Ran")
        #expect(SubagentPane.outputLabel(.command) == "Printed")
    }

    /// Monospace is for what a machine said or will run. A prompt is prose somebody wrote.
    @Test func aPromptIsProseAndACommandLineIsNot() {
        #expect(!SubagentPane.briefIsCode(.agent))
        #expect(SubagentPane.briefIsCode(.command))
    }

    // MARK: Staying live

    /// The bug this half of the work is about: the pane read its file once and, for a subagent
    /// that was still working, never again.
    @Test func aRunningSubagentKeepsBeingRead() {
        #expect(SubagentPane.refreshes(agent(state: .running)))
    }

    @Test func aFinishedSubagentIsNotPolled() {
        #expect(!SubagentPane.refreshes(agent(state: .completed)))
        #expect(!SubagentPane.refreshes(agent(state: .failed)))
        #expect(!SubagentPane.refreshes(agent(state: .stopped)))
        #expect(!SubagentPane.refreshes(nil))
    }

    /// The pane and the row must not disagree about how fresh they are: `tool_progress` ticks the
    /// row's seconds once a second, so the pane re-reads on the same clock.
    @Test func theRefreshIsTheSameSecondTheRowCountsIn() {
        #expect(SubagentPane.refreshSeconds == 1.0)
    }

    // MARK: The brief

    @Test func aShortBriefIsNotHiddenBehindAClick() {
        let short = "Read a.txt and report its line count."
        #expect(!SubagentPane.briefCollapses(short))
    }

    /// A handed-off brief runs to a page and a half. It used to open with the first 500 characters
    /// of it, which together with the title, the subtitle and the summary filled the pane, so what
    /// the subagent DID began below the fold of the one view somebody opens to find that out.
    @Test func aLongBriefOpensShutRatherThanShowingItsHead() {
        let long = String(repeating: "word ", count: 400)
        #expect(SubagentPane.briefCollapses(long))
    }

    /// The line that opens it says what is behind it. A shut brief draws no text at all, so "Show
    /// all" would be offering to show the rest of nothing.
    @Test func theLineThatOpensABriefNamesWhatItHides() {
        #expect(SubagentPane.briefToggle(isExpanded: false, kind: .agent) == "Show the prompt")
        #expect(SubagentPane.briefToggle(isExpanded: true, kind: .agent) == "Hide the prompt")
        #expect(SubagentPane.briefToggle(isExpanded: false, kind: .command) == "Show the command")
        #expect(SubagentPane.briefToggle(isExpanded: true, kind: .command) == "Hide the command")
    }

    // MARK: Finding what a command ran

    /// A `local_bash` task's own lines never carry the command, so it is lifted out of the
    /// parent's Bash call, which the transcript holds under the same `tool_use_id`.
    @Test func theCommandIsReadOffTheParentsToolCall() {
        let payload = Data("""
        {"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use",\
        "id":"toolu_01KuPv","name":"Bash","input":{"command":"npm run build",\
        "description":"Build frontend assets","run_in_background":true}}]}}
        """.utf8)
        #expect(SubagentPane.commandLine(inPayload: payload) == "npm run build")
    }

    @Test func aToolCallWithNoCommandAnswersNothingRatherThanEmptyText() {
        let payload = Data("""
        {"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use",\
        "id":"toolu_1","name":"Read","input":{"file_path":"/tmp/a.txt"}}]}}
        """.utf8)
        #expect(SubagentPane.commandLine(inPayload: payload) == nil)
        #expect(SubagentPane.commandLine(inPayload: Data("not json".utf8)) == nil)
        #expect(SubagentPane.commandLine(inPayload: Data()) == nil)
    }
}

// MARK: - Reading two different files

@Suite(.scratchDirectory) struct SubagentOutputReadingTests {
    /// The parent's session, which is the one these lines came off. Carried because a `Message`
    /// has one and for no other reason: nothing drawn from these rows reads it.
    private static let session = SessionID("s1")

    /// In the running test's own directory, which is removed when it ends. It used to be a fresh
    /// directory under `NSTemporaryDirectory()` that nothing removed, and there were 1,007 of them
    /// on the machine this was found on. See `TestScratch`.
    private func write(_ text: String, _ name: String = "out") throws -> String {
        let dir = URL(fileURLWithPath: TestScratch.unique("subagent"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// A background command's output file is bytes a program printed. Parsed as NDJSON it yields
    /// nothing at all, which is exactly what the pane was showing.
    @Test func aCommandsStdoutIsNotParsedAsATranscript() throws {
        let path = try write("> build\nassets written in 1.2s\n")
        let asTranscript = SubagentOutput.read(path: path, kind: .agent, sessionID: Self.session)
        #expect(try asTranscript.get().isEmpty)

        let printed = try SubagentOutput.read(path: path, kind: .command, sessionID: Self.session).get()
        #expect(printed.messages.isEmpty)
        #expect(printed.printed == "> build\nassets written in 1.2s")
    }

    @Test func anAgentsFileIsStillParsedAsNDJSON() throws {
        let path = try write("""
        {"type":"user","message":{"role":"user","content":"Count the lines"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"3"}]}}
        """)
        let transcript = try SubagentOutput.read(path: path, kind: .agent, sessionID: Self.session).get()
        // The brief is not one of the rows. It is drawn above the conversation, and reading it back
        // as something the subagent said is what drew it under "Answered" as well as under "Asked".
        #expect(transcript.prompt == "Count the lines")
        #expect(transcript.messages.map(\.kind) == [.assistantText])
    }

    @Test func aCommandThatPrintedNothingIsEmptyRatherThanABlankBlock() throws {
        let path = try write("   \n\n")
        #expect(try SubagentOutput.read(path: path, kind: .command, sessionID: Self.session).get().isEmpty)
    }

    /// The failure sentences are worded per kind. "This subagent's output" said of a `git push`
    /// running in the background is the same category error that put the two in one list, and an
    /// empty `output_file` is the ordinary case for a command rather than a fault.
    @Test func theFailureSentencesKnowWhatTheyAreTalkingAbout() {
        #expect(SubagentOutput.Failure.noFile.sentence(.agent).contains("subagent"))
        let command = SubagentOutput.Failure.noFile.sentence(.command)
        #expect(!command.contains("subagent"))
        #expect(command.contains("command"))
        #expect(SubagentOutput.Failure.missing.sentence(.command) == "This command has not printed anything yet.")
        for kind in SubagentKind.allCases {
            for failure: SubagentOutput.Failure in [.noFile, .missing, .unreadable("The file could not be opened.")] {
                #expect(failure.sentence(kind).hasSuffix("."))
                #expect(!failure.sentence(kind).contains("\u{2014}"))
                #expect(!failure.sentence(kind).contains("\u{2013}"))
            }
        }
    }

    /// The whole of a running subagent's pane. The CLI names its file on the line that ENDS the
    /// task, so until then the read above can only fail; the lines the subagent produced came past
    /// on the parent's own stream and Bloom stored every one of them.
    @Test func aRunningSubagentIsReadFromTheStreamBloomAlreadyStored() {
        let lines = [
            #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"role":"assistant","content":[{"type":"text","text":"Reading the diff"}]}}"#,
            #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/a/b.php"}}]}}"#,
            #"{"type":"user","parent_tool_use_id":"toolu_1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"<?php"}]}}"#,
        ].map { Data($0.utf8) }

        let live = SubagentTranscript.live(streamLines: lines, sessionID: Self.session)
        #expect(live.messages.map(\.kind) == [.assistantText, .toolUse, .toolResult])
        // The bytes of the line itself, so every renderer downstream reads what it always read.
        #expect(live.messages[0].payload == lines[0])
        #expect(live.messages[2].refID == "toolu_2")

        #expect(SubagentTranscript.live(streamLines: [], sessionID: Self.session).isEmpty)
    }

    /// **The brief was on screen twice, under two headings, and this is why.**
    ///
    /// In the CLI's file it is a `user` line whose content is a bare string. On the parent's live
    /// stream, which is what a RUNNING subagent's pane reads, it is a `user` line whose content is
    /// an array holding one `text` block. The reader used to look at the block's type without
    /// looking at whose message it was, so the brief came back as something the subagent had said.
    @Test func theBriefOnTheLiveStreamIsNotReadBackAsAnAnswer() {
        let lines = [
            #"{"type":"user","parent_tool_use_id":"toolu_1","message":{"role":"user","content":[{"type":"text","text":"You are implementing Tasks 7 and 8 of a plan for Assign."}]}}"#,
            #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"role":"assistant","content":[{"type":"text","text":"Both tasks are in."}]}}"#,
        ].map { Data($0.utf8) }

        let live = SubagentTranscript.live(streamLines: lines, sessionID: Self.session)
        #expect(live.prompt == "You are implementing Tasks 7 and 8 of a plan for Assign.")
        #expect(live.messages.count == 1)
        #expect(live.messages[0].kind == .assistantText)
    }

    /// A subagent that has not spoken yet has not failed to write anything, and the reasons in
    /// `SubagentOutput.Failure` are worded for one that has stopped.
    @Test func aWorkingSubagentWithNothingToShowIsNotDescribedAsAFailure() {
        #expect(SubagentPane.nothingToShow(.noFile, kind: .agent, isRunning: true)
            == "It has not said anything yet.")
        #expect(SubagentPane.nothingToShow(.noFile, kind: .command, isRunning: true)
            == "It has not printed anything yet.")
        #expect(SubagentPane.nothingToShow(.noFile, kind: .agent, isRunning: false)
            == SubagentOutput.Failure.noFile.sentence(.agent))
    }

    @Test func aFileThatIsNotThereIsASentenceRatherThanAThrow() {
        #expect(SubagentOutput.read(path: "/no/such/file", kind: .command, sessionID: Self.session)
            == .failure(.missing))
        #expect(SubagentOutput.read(path: "", kind: .command, sessionID: Self.session)
            == .failure(.noFile))
        #expect(SubagentOutput.read(path: nil, kind: .agent, sessionID: Self.session)
            == .failure(.noFile))
    }

    // MARK: Bounds

    /// The pane re-reads once a second now, so the read has to be bounded. It is the END that is
    /// kept, because that is where the answer is.
    @Test func onlyTheTailOfALongFileIsRead() throws {
        let line = String(repeating: "x", count: 999) + "\n"
        let path = try write("FIRST" + String(repeating: line, count: 400))
        let text = try SubagentOutput.tail(of: URL(fileURLWithPath: path))
        #expect(text.count <= SubagentOutput.tailBytes)
        #expect(!text.contains("FIRST"))
    }

    /// A file under the bound is returned whole, first line and all.
    @Test func aShortFileIsReadFromItsFirstByte() throws {
        let path = try write("FIRST\nsecond\n")
        #expect(try SubagentOutput.tail(of: URL(fileURLWithPath: path)).hasPrefix("FIRST"))
    }

    /// Half a JSON object is a skipped line; half a word of output is something somebody would
    /// have believed. So the partial first line goes.
    @Test func thePartialLineAtTheCutIsDropped() throws {
        let filler = String(repeating: "y", count: SubagentOutput.tailBytes)
        let path = try write("head\n" + filler + "\ntail line\n")
        let text = try SubagentOutput.tail(of: URL(fileURLWithPath: path))
        #expect(!text.hasPrefix("y"))
        #expect(text.hasSuffix("tail line\n"))
    }

    @Test func aTranscriptIsCappedAtWhatThePaneWillDraw() {
        // Numbered, so the rows are not all one payload and therefore not all one identity.
        let many = (0..<(SubagentTranscript.rowLimit + 30)).map {
            #"{"type":"assistant","uuid":"u\#($0)","message":{"content":[{"type":"text","text":"step"}]}}"#
        }.joined(separator: "\n")
        let transcript = SubagentTranscript.parse(many, sessionID: Self.session)
        #expect(transcript.messages.count == SubagentTranscript.rowLimit)
        #expect(transcript.droppedRows == 30)
    }

    @Test func anOrdinaryTranscriptReportsNothingDropped() {
        #expect(SubagentTranscript.parse("", sessionID: Self.session).droppedRows == 0)
    }
}
