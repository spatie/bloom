import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Answers one question, from several starting positions: **does asking for the live end actually
/// reach the very end?**
///
/// The sixth of the family, and the only one that is not about frame times. The others ask what a
/// gesture COST; this one asks whether a gesture DID WHAT IT SAID, because the bug it was written
/// for was not slow, it was wrong. The jump pill scrolled one frame, that frame posted
/// `boundsDidChange`, the coordinator read its own write as the reader taking hold, and the glide
/// stopped itself at nothing. With Reduce Motion on it worked, because that path jumps rather than
/// glides, which is exactly the kind of fault that survives a hand test: whoever checks it once,
/// in the wrong accessibility setting, comes away satisfied.
///
/// `TranscriptModel.submit` bumps the same counter, so "the chat does not scroll down when I say
/// something" was the same bug wearing different clothes. Both are covered here.
///
///     Bloom --jump-probe /tmp/jump.json --jump-workspace <id>
///           [--jump-settle 2500] [--window-size 1440x900]
///
/// **The bar is exact and it is not "nearly".** A run passes only where `NSScrollView.isAtEnd`
/// does, which is `TranscriptAnchor.isAtEnd` asked rather than restated: "did the instruction
/// survive", not `ScrollEnd.isAtEnd`'s "is the reader still following along". Ninety points short
/// passes the second and fails this one, and ninety points short is the newest row half off the
/// bottom of the window.
///
/// Programmatic, and never brought to the front, for the reason at the head of `ProbeHarness`:
/// the owner is at this Mac while it runs.
@MainActor
enum JumpProbe {
    private static let harness = ProbeHarness(subject: "jump")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var workspaceID: WorkspaceID? {
        ProbeHarness.value(for: "--jump-workspace").map(WorkspaceID.init)
    }

    /// How long a jump is given before it is judged, in milliseconds.
    ///
    /// Generous on purpose. The glide is a display link over a fixed duration, and the standing
    /// instruction it hands over to is re-asserted on the next run loop turn and again on every
    /// height correction, so the honest question is where the view came to rest rather than where
    /// it was a frame after the request.
    private static var settle: Duration {
        .milliseconds(ProbeHarness.count("--jump-settle", or: 2_500))
    }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    static func attach(_ model: AppModel) {
        guard isRequested else { return }
        ProbeHarness.attach(model)
    }

    private static func run() async {
        let (window, contentView) = await harness.window()

        guard let workspaceID else { harness.fail("--jump-workspace names no workspace") }
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
        guard let scroll = ProbeHarness.transcriptScrollView(in: contentView) else {
            harness.fail("no transcript NSScrollView found")
        }

        let travel = scroll.endOffset
        guard travel > 1 else {
            harness.fail("the transcript is shorter than its viewport, so there is nowhere to jump from")
        }

        harness.markStarted()

        var cases: [JSONValue] = []
        // The four the owner named, plus the one only a probe can hold still: a jump requested
        // while the tail is growing under it.
        cases.append(await jump(named: "from the very top", to: 0, scroll: scroll, transcript: transcript))
        cases.append(await jump(named: "from the middle", to: travel / 2, scroll: scroll, transcript: transcript))
        cases.append(await jump(
            named: "from one screen up", to: travel - scroll.contentView.bounds.height,
            scroll: scroll, transcript: transcript
        ))
        cases.append(await jump(
            named: "from just above the end", to: travel - 120, scroll: scroll, transcript: transcript
        ))
        cases.append(await jumpWhileStreaming(scroll: scroll, transcript: transcript, travel: travel))

        let failures = cases.filter { !isPass($0) }.count

        harness.write(.object([
            "workspace": .string(workspaceID.rawValue),
            "workspaceName": .string(model.workspace.name),
            "sessionRows": .integer(transcript.rows.count),
            "scrollableHeight": .number(Double(travel)),
            "cases": .array(cases),
            // The single number to read first. Anything but nought means the bar was not met, and
            // the bar is the owner's own words: it should always go completely down.
            "failures": .integer(failures),
        ].merging(harness.conditions(window: window)) { mine, _ in mine }))
        exit(0)
    }

    // MARK: - One case

    /// Puts the view at `origin`, asks for the live end, and reports where it came to rest.
    private static func jump(
        named name: String, to origin: CGFloat, scroll: NSScrollView, transcript: TranscriptModel
    ) async -> JSONValue {
        put(scroll, at: max(0, origin))
        // A beat, so the standing instruction is genuinely released by the move above rather than
        // still in force from the last case, which would make this pass without being asked.
        try? await Task.sleep(for: .milliseconds(600))
        let before = scroll.distanceFromEnd

        transcript.jumpToLiveEnd()
        try? await Task.sleep(for: settle)

        return verdict(name: name, before: before, scroll: scroll)
    }

    /// The same request, made while the tail is growing under it.
    ///
    /// The case the two reported bugs actually happen in: a turn is running, rows are landing, the
    /// heights of the rows already drawn are still being corrected, and every one of those moves
    /// where "the end" is. A jump that reaches the end and is then left behind by the next arrival
    /// has not done what it was pressed for.
    private static func jumpWhileStreaming(
        scroll: NSScrollView, transcript: TranscriptModel, travel: CGFloat
    ) async -> JSONValue {
        put(scroll, at: travel / 2)
        try? await Task.sleep(for: .milliseconds(600))
        let before = scroll.distanceFromEnd

        transcript.jumpToLiveEnd()
        // Deltas across the whole settle, so the tail is still growing when the verdict is taken.
        let text = String(repeating: "measured ", count: 6)
        for _ in 0..<40 {
            await transcript.acceptForProbe(.streamDelta(.text(text)))
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: settle)

        var report = verdict(name: "while the tail is growing", before: before, scroll: scroll)
        if case .object(var fields) = report {
            fields["tailCharacters"] = .integer(transcript.streamingText.count)
            report = .object(fields)
        }
        return report
    }

    // MARK: - Measuring

    private static func verdict(name: String, before: CGFloat, scroll: NSScrollView) -> JSONValue {
        let after = scroll.distanceFromEnd
        return .object([
            "case": .string(name),
            "pointsFromEndBefore": .number(Double(before)),
            "pointsFromEndAfter": .number(Double(after)),
            // The bar itself, asked of the type that owns it rather than written out again here.
            "atEnd": .bool(scroll.isAtEnd),
            // What the OTHER question would have said, because the two disagreeing is the shape
            // of the bug: a jump that stops ninety points short looks fine to everything that
            // asks whether the reader is following along.
            "wouldPassAsFollowing": .bool(after < ScrollEnd.threshold),
        ])
    }

    private static func isPass(_ report: JSONValue) -> Bool {
        guard case .object(let fields) = report, case .bool(let atEnd)? = fields["atEnd"] else {
            return false
        }
        return atEnd
    }

    /// Written straight onto the clip view for `ScrollProbe`'s reason: `scroll(to:)` animates for
    /// some callers, and an animated move would still be running when the jump is asked for.
    private static func put(_ scroll: NSScrollView, at origin: CGFloat) {
        let clip = scroll.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: origin))
        scroll.reflectScrolledClipView(clip)
    }
}
