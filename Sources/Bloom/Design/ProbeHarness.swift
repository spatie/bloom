import AppKit
import Foundation
import Synchronization
import BloomCore

/// The machinery six probes were each written with their own copy of.
///
/// `FrameProbe`, `SwitchProbe`, `TabProbe`, `ScrollProbe`, `IdleProbe` and `ResizeProbe` measure
/// six different gestures and shared almost everything else. Counted before this existed:
/// `value(for:)` in seven copies byte for byte, the `WxH` parse in five, the sixty iteration
/// window wait in four, `systemLoadAverage` and `buildConfiguration` in three each, and `fail` six
/// times in two different signatures. That was the largest duplicate mass in the tree, ahead of
/// `AgentRunner` and `CodexRunner`.
///
/// # Why it was worth a file rather than a shrug
///
/// Because it had already drifted, and the drift cost measurements rather than tidiness.
/// `SwitchProbe`, `TabProbe` and, because it was copied from one of them, `ResizeProbe` checked a
/// report before serialising it. `FrameProbe`, `ScrollProbe` and `IdleProbe` did not, so half the
/// family could still die on the last line of a run. The lesson was written down three times, in
/// the three files that could not teach it to the other three, and the seventh probe would have
/// inherited whichever half it was written from.
///
/// **The bug that lesson came from, and why nothing here can have it again.** A report used to be
/// a `[String: Any]`, so a typed id went in without complaint and arrived at `JSONSerialization`
/// as `__SwiftValue`. `JSONSerialization` raises on a value it cannot carry rather than throwing
/// one, an Objective-C exception is not something `try?` catches, and the probe died at the very
/// end of a twenty minute run, after every measurement had been taken and before any of it was on
/// disk. A report is a `JSONValue` now (`BloomCore`, `Sendable`, `Codable`, and with no case that
/// can hold a `WorkspaceID`), so the same mistake is a compile error at the line that makes it.
/// The runtime guard the two probes carried is gone because there is nothing left for it to
/// catch, which is the only kind of check worth deleting.
///
/// # What is NOT here
///
/// Every probe's driver and subject: a divider drag, a workspace selection, a tab pick, a scroll,
/// an idle pass, a window resize. Those are what the six files are actually about, they are all
/// different, and the arguments in their heads for why each is shaped as it is are the value in
/// them. `FrameProbe` has two drivers because each answers a different objection; `TabProbe` has
/// one and will never have a second. A harness that flattened either would have made the tree
/// worse.
@MainActor
struct ProbeHarness {
    /// The probe's own word: `frame`, `switch`, `tab`, `scroll`, `idle`, `resize`.
    ///
    /// The flag, the default report path and the name in front of every line on stderr all follow
    /// from it, because all six spelled all three the same way and a seventh should not have to be
    /// told how.
    let subject: String

    /// `--frame-probe`, whose value names the report to write.
    var flag: String { "--\(subject)-probe" }

    /// "frame probe", which is how a line on stderr introduces itself.
    var name: String { "\(subject) probe" }

    var isRequested: Bool { CommandLine.arguments.contains(flag) }

    var outputPath: String {
        Self.value(for: flag) ?? (NSTemporaryDirectory() + "bloom-\(subject)-probe.json")
    }

    // MARK: - Arguments

    /// The value after a flag, or nil if the flag is absent or last.
    ///
    /// A hand-rolled scan rather than anything cleverer, because these flags are read before any
    /// scene exists and half of them are read by a probe that is about to refuse the run.
    static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func text(_ flag: String, or fallback: String) -> String {
        value(for: flag) ?? fallback
    }

    static func count(_ flag: String, or fallback: Int) -> Int {
        Int(value(for: flag) ?? "") ?? fallback
    }

    static func points(_ flag: String, or fallback: CGFloat) -> CGFloat {
        CGFloat(Double(value(for: flag) ?? "") ?? Double(fallback))
    }

    static func isPresent(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag)
    }

    // MARK: - The window

    /// The seconds a run gives a launch before it touches anything.
    ///
    /// Its own method because `IdleProbe` waits and has no window to wait for: what it measures is
    /// the work the six second diff loop does, and a launch's own git reads landing inside the
    /// first pass would be counted as the loop's.
    func settle() async {
        try? await Task.sleep(for: .seconds(3))
    }

    /// The window a run measures, once there is one and once it is the size the run asked for.
    ///
    /// **The app is deliberately never brought to the front here.** A probe run happens while the
    /// owner is using his own copy of Bloom, and an activation would take his keyboard. The two
    /// drivers that cannot work without the front, `FrameProbe`'s mouse and `SwitchProbe`'s click,
    /// activate for themselves and each says why beside the call.
    ///
    /// The wait loop is a loop because there is no window for the first moments of a launch, and
    /// a probe that asked once got nil and reported nothing at all.
    func window() async -> (window: NSWindow, content: NSView) {
        await settle()
        for _ in 0..<60 {
            let candidate = NSApp.windows.first {
                $0.isVisible && $0.contentView != nil && $0.parent == nil
                    && $0.styleMask.contains(.titled)
            }
            if let candidate, let content = candidate.contentView {
                await resize(candidate)
                return (candidate, content)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        fail("no window to probe")
    }

    /// `--window-size 1440x900`, applied and given a second to settle.
    ///
    /// A size that cannot be read ends the run rather than being ignored, which is a change from
    /// the five copies this replaces. A run that silently measured whatever size the window was
    /// last left at, while its report named the size that was asked for, is a run whose number
    /// means something other than what it says.
    private func resize(_ window: NSWindow) async {
        guard let raw = Self.value(for: "--window-size") else { return }
        guard let size = ProbeStats.windowSize(raw) else {
            fail("--window-size wants WxH, as in 1440x900, and was given \(raw)")
        }
        window.setContentSize(size)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: - Reaching the model

    /// The app's state, weakly, because a probe has no business keeping the app alive.
    ///
    /// Handed over from two places on purpose. `AppModel.bootstrap` sets `probeInstance` and
    /// `BloomAppDelegate` calls `attach`, and the two moments are not ordered against each other,
    /// so a probe takes whichever of them has landed.
    private static weak var attached: AppModel?

    static func attach(_ model: AppModel) {
        attached = model
    }

    static var appModel: AppModel? { attached ?? AppModel.probeInstance }

    // MARK: - Synthetic events

    /// One mouse event, delivered to THIS process and to nothing else.
    ///
    /// `postToPid` takes a pid, so a probe driving a drag or a click never goes near another
    /// application whatever is under the pointer.
    nonisolated static func post(_ type: CGEventType, at point: CGPoint, pid: pid_t) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.postToPid(pid)
    }

    /// Runs a burst of synthetic events on a thread of its own and waits for it from here.
    ///
    /// Posted from a thread rather than from the main actor because pacing from the main thread
    /// would mean the drag slowed down exactly when the main thread got busy, which is the thing
    /// being measured. Waited on by yielding rather than by blocking, because the tracking loop
    /// that consumes these events IS the main thread, and a blocked main thread consumes nothing.
    ///
    /// `polling` is the caller's, not a constant, because it is main actor time spent inside the
    /// measurement and each driver chose its own.
    func onEventThread(polling: Duration, _ work: @escaping @Sendable () -> Void) async {
        let done = Mutex(false)
        Thread.detachNewThread {
            work()
            done.withLock { $0 = true }
        }
        while !done.withLock({ $0 }) {
            await Task.yield()
            try? await Task.sleep(for: polling)
        }
    }

    // MARK: - The transcript's scroll view

    /// The transcript's scroll view, picked as the one with the most to scroll.
    ///
    /// By document height rather than by position or by class name. The window holds several
    /// scroll views (the sidebar, the inspector's file list, the transcript, sometimes a diff),
    /// and a private SwiftUI class name would be a guess a future release breaks silently. A
    /// transcript with a few hundred messages in it is an order of magnitude taller than any of
    /// the others.
    ///
    /// Here rather than in `ScrollProbe`, which is where it was written, because `SwitchProbe`
    /// needs the same view to answer a different question: where a workspace switch left the
    /// reader.
    static func transcriptScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found.max { $0.endOffset < $1.endOffset }
    }

    /// Where a transcript is standing, as a report says it.
    ///
    /// `atEnd` is the one that matters to a reader: "I was at the bottom, I went away, I came
    /// back".
    ///
    /// Four points, which is its own number and not `NSScrollView.isAtEnd`'s one: this records
    /// where a switch left a reader rather than asserting that an instruction survived, and the
    /// live end of a list whose last row has just been measured is a point or two from the bottom
    /// of the content. `JumpProbe` is the one that wants the exact question and asks it.
    static func scrollPlace(_ scroll: NSScrollView?) -> [String: JSONValue] {
        guard let scroll else { return ["found": .bool(false)] }
        let offset = Double(scroll.contentView.bounds.origin.y)
        let content = Double(scroll.documentView?.frame.height ?? 0)
        let viewport = Double(scroll.contentView.bounds.height)
        let reach = Double(scroll.distanceFromEnd)
        return [
            "found": .bool(true),
            "offset": .number(offset),
            "contentHeight": .number(content),
            "viewportHeight": .number(viewport),
            "reachToEnd": .number(reach),
            "atEnd": .bool(reach <= 4),
        ]
    }

    /// Scrolls a view the way a wheel does, from inside this process.
    ///
    /// **Writing the clip view's bounds is not scrolling, and the difference is what this exists
    /// for.** SwiftUI's `ScrollPosition` never sees a bounds write, so it goes on standing at
    /// whatever edge it was left at and the next layout pass that grows the content puts the view
    /// back there: a probe that asked for two thousand points off the live end reported `atEnd` on
    /// both samples. A scroll wheel event goes through the same path a hand does, so the position
    /// moves off its edge exactly as it would for a reader.
    ///
    /// Delivered by calling `scrollWheel(with:)` on the view rather than by posting to the window
    /// server. Posting would route by where the pointer is, which is somewhere in the owner's own
    /// window, and would need this app in front. Nothing here takes the pointer, the focus or the
    /// front. See the head of `window`.
    static func wheel(_ view: NSView, by points: CGFloat, steps: Int = 1) {
        for _ in 0..<max(1, steps) {
            guard let scroll = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(points),
                wheel2: 0,
                wheel3: 0
            ), let event = NSEvent(cgEvent: scroll) else { return }
            view.scrollWheel(with: event)
        }
    }

    // MARK: - What a report says about the run

    /// Which build, how loaded the machine was, and what the window was.
    ///
    /// All three on every report, where three of the six carried only some of them. A wall clock
    /// frame interval is a measurement of this Mac as well as of this app, and this Mac has other
    /// agents building on it, so a number taken at a load average of thirty has to be
    /// recognisable as one rather than believed. `ScrollProbe` could not say which build it had
    /// measured at all.
    func conditions(window: NSWindow?) -> [String: JSONValue] {
        var conditions: [String: JSONValue] = [
            "configuration": .string(Self.buildConfiguration),
            "loadAverage": .number(Self.systemLoadAverage()),
        ]
        guard let window else { return conditions }
        conditions["windowSize"] = .object([
            "w": .number(window.frame.width), "h": .number(window.frame.height),
        ])
        conditions["displayHz"] = .number(Double(window.screen?.maximumFramesPerSecond ?? 60))
        return conditions
    }

    /// The frame timings `ScrollProbe` and `ResizeProbe` both report, from a list of frame
    /// intervals in milliseconds.
    ///
    /// Sorted here rather than by the caller. Every number below is a rank or the top of the list,
    /// so a caller that handed this an unsorted list would get a plausible report full of wrong
    /// numbers, and no probe would notice.
    ///
    /// The dropped frame threshold is this run's own median rather than a fixed 16.7, because this
    /// Mac may be running at 120Hz and calling every 10ms frame a stutter on a 60Hz panel would
    /// report a problem nobody can see. `FrameProbe` counts against 16.7 and 33.4 instead, and
    /// that is not an oversight in this one: its question is how many frames missed a 60Hz
    /// deadline, which is a claim about the deadline rather than about the run.
    static func frameTimings(_ intervals: [Double]) -> [String: JSONValue] {
        let ms = intervals.sorted()
        let median = ProbeStats.percentile(0.5, of: ms)
        let dropped = ms.filter { $0 > (ms.isEmpty ? 8.3 : median) * 1.8 }.count
        return [
            "frames": .integer(ms.count),
            "medianMs": .number(median),
            "medianFps": .number(median > 0 ? 1000 / median : 0),
            "p95Ms": .number(ProbeStats.percentile(0.95, of: ms)),
            "p99Ms": .number(ProbeStats.percentile(0.99, of: ms)),
            "worstMs": .number(ms.last ?? 0),
            "droppedFrames": .integer(dropped),
            "droppedShare": .number(ms.isEmpty ? 0 : Double(dropped) / Double(ms.count)),
        ]
    }

    static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    static func systemLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return loads[0]
    }

    /// How much CPU the main thread has burned since this process started.
    ///
    /// Read either side of a measured pass, because a wall clock frame interval says what a
    /// gesture feels like on the machine it was taken on, and CPU per step of the same gesture
    /// barely moves when the load average does. The second is the number two builds can be
    /// compared with while three other agents are building.
    static func mainThreadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    // MARK: - Writing it down

    /// A marker on disk saying the measured pass has begun.
    ///
    /// On disk rather than on stderr so a shell watching for it can start `sample` against this
    /// pid at the moment the measurement starts, instead of profiling twenty seconds of a window
    /// loading a transcript.
    func markStarted() {
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: URL(fileURLWithPath: outputPath + ".started"))
    }

    /// The report, on disk and named on stderr.
    ///
    /// `.sortedKeys` on every report rather than on two of the five, so any two runs can be
    /// diffed against each other. `echo` puts the whole report on stderr as well, which is how
    /// `IdleProbe` is read: its runs are short and are driven from a shell that never opens the
    /// file.
    func write(_ report: JSONValue, echo: Bool = false) {
        guard let data = Self.encoded(report) else {
            fail("the report could not be encoded")
        }
        try? data.write(to: URL(fileURLWithPath: outputPath))
        if echo {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        FileHandle.standardError.write(Data("\(name) wrote \(outputPath)\n".utf8))
    }

    /// One signature for all six, where there used to be two.
    ///
    /// `Never`, so a caller can end a run with it from inside a `guard`. Three of the six returned
    /// `Void` and were written `return fail(...)`, which reads the same and works only where the
    /// caller happens to be able to return, so those three could not refuse a run from a `guard`
    /// at all.
    ///
    /// **A failed run leaves a report saying so**, which none of the six except `IdleProbe` did.
    /// The report path is reused between runs, so a run that failed and left the last one's file
    /// on disk is a run somebody reads as this one's answer, at a glance, with every number in it
    /// looking exactly as plausible as it did an hour ago.
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(name): \(message)\n".utf8))
        let report = JSONValue.object([
            "probe": .string(name),
            "error": .string(message),
            "configuration": .string(Self.buildConfiguration),
        ])
        if let data = Self.encoded(report) {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }
        exit(1)
    }

    /// Deliberately not `write`'s body: `write` ends a hopeless encode with `fail`, and `fail`
    /// writes a report of its own, so one of the two has to be the one that cannot recurse.
    private static func encoded(_ report: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(report)
    }
}

/// The shapes a probe's own instruments hand back, as JSON.
///
/// Written out here rather than at each call site, because the alternative to six of these is a
/// `[String: Any]` and a dynamic cast, which is the hole the whole family fell down. Everything
/// below is typed: nothing in a report can be a value JSON cannot carry.
extension JSONValue {
    static func numbers(_ values: [Double]) -> JSONValue {
        .array(values.map { .number($0) })
    }

    static func numbers(_ values: [CGFloat]) -> JSONValue {
        .array(values.map { .number(Double($0)) })
    }

    static func numbers(_ rows: [[Double]]) -> JSONValue {
        .array(rows.map { numbers($0) })
    }

    static func strings(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
    }

    static func map(_ values: [String: Double]) -> JSONValue {
        .object(values.mapValues { .number($0) })
    }

    static func map(_ values: [String: [String: Double]]) -> JSONValue {
        .object(values.mapValues { map($0) })
    }

    static func map(_ values: [String: [[Double]]]) -> JSONValue {
        .object(values.mapValues { numbers($0) })
    }
}
