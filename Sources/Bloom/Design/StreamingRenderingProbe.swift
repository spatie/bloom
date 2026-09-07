import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// Measures the real streaming markdown row without an agent, a user transcript or synthetic
/// input. This isolates rendering cost; it does not claim to measure foreground auto-scrolling.
@MainActor
enum StreamingRenderingProbe {
    private static let harness = ProbeHarness(subject: "streaming-rendering")
    static var isRequested: Bool { harness.isRequested }
    static func schedule() { Task { @MainActor in await run() } }

    private static func run() async {
        guard Bundle.main.bundleIdentifier?.hasPrefix("be.spatie.bloom.typography-") == true else {
            harness.fail("requires a disposable probe bundle")
        }
        _ = await harness.window()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [], backing: .buffered, defer: false
        )
        let app = AppModel()
        let workspace = Workspace(
            repoID: RepoID(UUID().uuidString), name: "Streaming rendering probe", branch: "probe",
            path: "/nonexistent-bloom-rendering-probe", baseBranch: "main"
        )
        let transcript = TranscriptModel(
            session: Session(workspaceID: workspace.id, title: "Probe"), workspace: workspace, app: app
        )
        let host = NSHostingView(rootView: ScrollView {
            StreamingRowView(transcript: transcript).frame(width: 760)
        })
        host.sizingOptions = []
        window.contentView = host
        let paragraph = "A completed paragraph with **emphasis**, `inline code` and enough words to wrap across several lines while the next paragraph arrives.\n\n"
        let prefix = String(repeating: paragraph, count: 40)
        await transcript.acceptForProbe(.streamDelta(.text(prefix)))
        try? await Task.sleep(for: .milliseconds(500))
        let recorder = FrameRecorder(view: host) { CGFloat(transcript.streamingText.count) }
        recorder.start()
        harness.markStarted()
        let cpu = ProbeHarness.mainThreadCPUSeconds()
        let start = CACurrentMediaTime()
        let chunk = "More **streamed** words arriving in this paragraph. "
        for index in 0..<200 {
            await transcript.acceptForProbe(.streamDelta(.text(chunk + (index % 4 == 3 ? "\n\n" : ""))))
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
        let elapsed = CACurrentMediaTime() - start
        let consumed = ProbeHarness.mainThreadCPUSeconds() - cpu
        recorder.stop()
        let expected = prefix.count + chunk.count * 200 + 100
        harness.write(.object([
            "characters": .integer(transcript.streamingText.count),
            "complete": .bool(transcript.streamingText.count == expected),
            "wallSeconds": .number(elapsed), "mainThreadCpuMs": .number(consumed * 1000),
            "frames": .object(ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })),
        ].merging(harness.conditions(window: window)) { mine, _ in mine }))
        exit(0)
    }
}
