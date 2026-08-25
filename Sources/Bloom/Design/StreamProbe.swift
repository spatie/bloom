import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Measures the two states Bloom actually spends its day in: somebody typing, and an agent
/// writing.
///
/// The seventh of the family, and the first that does not measure a gesture. `FrameProbe`,
/// `SwitchProbe`, `TabProbe`, `ScrollProbe` and `ResizeProbe` all drive something a hand does to a
/// window and then let go; `IdleProbe` measures the app with nobody in it. **None of them measures
/// the app being used**, and the two ways it is used all day are a prompt being written and a turn
/// arriving. Both were argued about from the mechanism and neither had a number.
///
/// # What each half drives, and why it is driven this way
///
/// **Typing** goes through `NSTextView.insertText`, on the real composer, one character at a time.
/// Not synthetic key events: the owner may be at this Mac, and a probe that posted keys would need
/// the window in front and would take his keyboard. `TabProbe` makes the same trade and says so.
/// What is lost is AppKit's own key handling, which is the same in every application; what is kept
/// is the whole of what a keystroke costs this app, because `insertText` runs the delegate, the
/// draft binding, the chip scan, the height report and every body they invalidate.
///
/// **Streaming** pushes real `AgentEvent.streamDelta` values into the transcript's own event
/// handler, at a fixed rate. Not a real agent: `BLOOM_LIVE` costs money, a model's pace is not
/// repeatable, and what is being measured is what Bloom does with a delta rather than how fast one
/// arrives. Every delta travels the path a real one does, which is why `TranscriptModel` has one
/// door for this and it is named after this file.
///
///     Bloom --stream-probe /tmp/stream.json --stream-workspace <id>
///           [--stream-typed 120] [--stream-deltas 200] [--stream-chunk 14]
///           [--stream-rate 25] [--window-size 1440x900]
///
/// `--stream-rate` is deltas per second, which is roughly what Claude Code emits at full tilt.
/// `--stream-chunk` is characters per delta. The two together are the shape of a real turn; what
/// the report says is what each one cost the window.
///
/// Everything that is not the typing and the streaming is `ProbeHarness`: the flags, the window,
/// the model, the failure, the frame timings, the report.
@MainActor
enum StreamProbe {
    private static let harness = ProbeHarness(subject: "stream")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var workspaceID: WorkspaceID? {
        ProbeHarness.value(for: "--stream-workspace").map(WorkspaceID.init)
    }

    private static var typed: Int { ProbeHarness.count("--stream-typed", or: 120) }
    private static var deltas: Int { ProbeHarness.count("--stream-deltas", or: 200) }
    private static var chunk: Int { ProbeHarness.count("--stream-chunk", or: 14) }
    private static var rate: Int { max(1, ProbeHarness.count("--stream-rate", or: 25)) }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    static func attach(_ model: AppModel) {
        guard isRequested else { return }
        ProbeHarness.attach(model)
    }

    private static func run() async {
        // Not brought to the front, for the reason at the head of `ProbeHarness.window`.
        let (window, contentView) = await harness.window()

        guard let workspaceID else { harness.fail("--stream-workspace names no workspace") }
        OpenWorkspaceNotification.post(workspaceID)
        // Long enough for the transcript to load every row and for the inspector to settle.
        try? await Task.sleep(for: .seconds(8))

        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let model = app.existingModel(for: workspaceID) else {
            harness.fail("workspace \(workspaceID.rawValue) is not open")
        }
        guard let session = model.activeSession,
              let transcript = model.existingTranscript(for: session.id) else {
            harness.fail("workspace \(workspaceID.rawValue) has no conversation open")
        }
        guard let editor = composer(in: contentView) else {
            harness.fail("no composer text view found")
        }

        let recorder = FrameRecorder(view: contentView) { CGFloat(transcript.rows.count) }

        harness.markStarted()

        // Typing first, and into an empty draft, so the two halves cannot be measuring each
        // other: a live tail on screen would be under every keystroke of the second half.
        let typing = await measureTyping(editor: editor, transcript: transcript, recorder: recorder)
        let streaming = await measureStreaming(transcript: transcript, recorder: recorder)

        harness.write(.object([
            "workspace": .string(workspaceID.rawValue),
            "workspaceName": .string(model.workspace.name),
            // What the pane was holding, because a run against a short conversation is a run whose
            // numbers mean something else. Every probe here has learned that the hard way.
            "sessionRows": .integer(transcript.rows.count),
            "typing": .object(typing),
            "streaming": .object(streaming),
        ].merging(harness.conditions(window: window)) { mine, _ in mine }))
        exit(0)
    }

    // MARK: - Typing

    /// One character at a time into the real composer, with the frame timings either side.
    ///
    /// The pace is one character per frame at most, which is faster than anybody types and is the
    /// point: a keystroke that costs more than a frame shows up as a frame interval longer than a
    /// frame, and a probe that typed slowly would leave room for the cost to hide in.
    private static func measureTyping(
        editor: ComposerTextView, transcript: TranscriptModel, recorder: FrameRecorder
    ) async -> [String: JSONValue] {
        editor.window?.makeFirstResponder(editor)
        let sentence = Array("the quick brown fox jumps over the lazy dog. ")
        var typedCharacters = 0

        recorder.start()
        let cpuBefore = ProbeHarness.mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        for index in 0..<typed {
            editor.insertText(String(sentence[index % sentence.count]), replacementRange: NSRange(location: NSNotFound, length: 0))
            typedCharacters += 1
            // One vsync, so each keystroke is measured against a frame rather than against the
            // one before it.
            try? await Task.sleep(for: .milliseconds(8))
        }
        let wall = CACurrentMediaTime() - wallBefore
        let cpu = ProbeHarness.mainThreadCPUSeconds() - cpuBefore
        recorder.stop()

        // The draft goes, so the streaming half is measured over the composer the reader would
        // actually be looking at and so the dev database is not left holding a page of foxes.
        transcript.draft = ""

        var report = ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })
        report["characters"] = .integer(typedCharacters)
        report["wallSeconds"] = .number(wall)
        report["mainThreadCpuMsPerKeystroke"] = .number(
            typedCharacters > 0 ? cpu * 1000 / Double(typedCharacters) : 0
        )
        // A run whose keystrokes never reached the draft measured an empty composer.
        report["didType"] = .bool(typedCharacters > 0)
        return report
    }

    // MARK: - Streaming

    /// Real deltas through the transcript's own handler, at a fixed rate.
    private static func measureStreaming(
        transcript: TranscriptModel, recorder: FrameRecorder
    ) async -> [String: JSONValue] {
        let text = String(repeating: "x", count: max(1, chunk))
        let gap = Duration.milliseconds(1000 / rate)

        recorder.start()
        let cpuBefore = ProbeHarness.mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        for _ in 0..<deltas {
            await transcript.acceptForProbe(.streamDelta(.text(text + " ")))
            try? await Task.sleep(for: gap)
        }
        let wall = CACurrentMediaTime() - wallBefore
        let cpu = ProbeHarness.mainThreadCPUSeconds() - cpuBefore
        recorder.stop()

        var report = ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })
        report["deltas"] = .integer(deltas)
        report["chunkCharacters"] = .integer(chunk)
        report["ratePerSecond"] = .integer(rate)
        report["wallSeconds"] = .number(wall)
        report["mainThreadCpuMsPerDelta"] = .number(
            deltas > 0 ? cpu * 1000 / Double(deltas) : 0
        )
        // The tail really did grow, which is the check every probe here owes its own numbers.
        report["tailCharacters"] = .integer(transcript.streamingText.count)
        return report
    }

    // MARK: - Finding the composer

    /// The composer's own text view, by type rather than by position.
    ///
    /// A window can hold several text views: every prose row of the transcript is one, and so is
    /// the review comment field. Only the composer is a `ComposerTextView`, and it is the deepest
    /// one this walk finds first because the composer sits at the foot of the centre column.
    private static func composer(in root: NSView) -> ComposerTextView? {
        if let editor = root as? ComposerTextView { return editor }
        for subview in root.subviews {
            if let found = composer(in: subview) { return found }
        }
        return nil
    }
}
