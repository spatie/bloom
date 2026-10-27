import AppKit
import QuartzCore
import SwiftUI
import Vision
import BloomCore

/// The scroll lab's driver: the real window content, in a window nobody sees, scrolled with real
/// scroll events, and written down frame by frame.
///
/// `Tools/scroll-lab.sh` compiles this file into several revisions of the app, including ones from
/// before the transcript was a table, so it reaches for nothing but `AppModel`, `RootView`, the
/// store and AppKit. Everything that judges a run lives in `Tools/scroll-lab.py`, which reads the
/// trace: a new invariant there costs no rebuild of the revisions it compares.
///
/// **Its own window, because a background launch opens none.** `open -g` on a bundle with no
/// saved state never shows the main scene, so the probes that wait for it report "no window to
/// probe". This one hosts `RootView` itself, transparent and ignoring the mouse, ordered in so
/// the display link and the display cycle run as they would for a reader.
@MainActor
enum ScrollLab {
    static var isRequested: Bool { CommandLine.arguments.contains("--scroll-lab") }

    static func runAndExit() -> Never {
        let safe = ProcessInfo.processInfo.environment["BLOOM_DB_PATH"] != nil
            && Bundle.main.bundleIdentifier?.hasPrefix("be.spatie.bloom.scroll-lab") == true
        guard safe else {
            FileHandle.standardError.write(Data("scroll lab: refusing to run outside its own bundle and database\n".utf8))
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in await ScrollLabRun().run() }
        NSApplication.shared.run()
        exit(1)
    }
}

/// A window that keeps the size it is given. A titled window is otherwise pulled inside the
/// screen's visible frame, and a run measured at a size other than the one its report names
/// measures something else.
private final class ScrollLabWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The app's root, sized like the app's own `Window` scene, which follows only the content's minimum
/// size: the default options also work out its ideal and largest size on every update. Counts every
/// relayout asked of it, which each step records: a moving transcript asks for one about two
/// hundred times a second, from SwiftUI's own hosting of the moving cells.
private final class ScrollLabRootView<Content: View>: NSHostingView<Content> {
    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            super.needsLayout = newValue
            if newValue { ScrollLabRootRelayouts.count += 1 }
        }
    }
}

@MainActor
private enum ScrollLabRootRelayouts {
    static var count = 0
}

@MainActor
private final class ScrollLabRun: NSObject {
    private let output: FileHandle
    private let plan: [[String: Any]]
    private var size: CGSize
    private var app: AppModel?
    private var window: NSWindow?
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()

    private var scroll: NSScrollView?
    private var scrollIndex: [ObjectIdentifier: Int] = [:]
    private var frames: [[Double]] = []
    private var captures: [String: [[Double]]] = [:]
    private var appending: Task<Void, Never>?

    override init() {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let path = value("--scroll-lab") ?? NSTemporaryDirectory() + "scroll-lab.ndjson"
        FileManager.default.createFile(atPath: path, contents: nil)
        output = FileHandle(forWritingAtPath: path) ?? .standardError
        let planData = value("--scroll-lab-plan").flatMap { FileManager.default.contents(atPath: $0) }
        let decoded = planData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        plan = decoded?["steps"] as? [[String: Any]] ?? []
        let width = decoded?["width"] as? Double ?? 1440
        let height = decoded?["height"] as? Double ?? 900
        size = CGSize(width: width, height: height)
        super.init()
    }

    // MARK: - Running

    func run() async {
        // App Nap would stretch every timer and frame in a process nobody is looking at.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "scroll lab"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let app = AppModel()
        await app.bootstrap()
        for _ in 0..<600 where !app.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
        self.app = app
        write(["kind": "boot", "loaded": app.isLoaded, "workspaces": app.workspaces.count,
               "configuration": configuration, "load": loadAverage()])

        openWindow(app)
        startRecording()
        for (index, step) in plan.enumerated() {
            await perform(step, index: index)
        }
        finish(0)
    }

    private func finish(_ status: Int32) -> Never {
        link?.invalidate()
        write(["kind": "end", "t": now()])
        try? output.synchronize()
        exit(status)
    }

    private func openWindow(_ app: AppModel) {
        let window = ScrollLabWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let root = ScrollLabRootView(rootView: RootView().environment(app))
        root.sizingOptions = [.minSize]
        window.contentView = root
        window.setFrame(CGRect(origin: .zero, size: size), display: false)
        // Ordered in, never made key: the display link only runs for a window on a screen.
        window.orderFrontRegardless()
        self.window = window
    }

    // MARK: - Recording

    private func now() -> Double { CACurrentMediaTime() - started }

    private func startRecording() {
        guard let content = window?.contentView else { return }
        let link = content.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// One frame: the clock, where the transcript stands, and how tall it is. Nothing here walks
    /// a view tree, because a probe whose per frame cost grows with the document reports itself.
    @objc private func tick() {
        guard let scroll, scroll.window != nil else {
            frames.append([now(), -1, -1, -1, -1])
            return
        }
        frames.append([
            now(),
            Double(scroll.contentView.bounds.origin.y),
            Double(scroll.documentView?.frame.height ?? 0),
            Double(scroll.contentView.bounds.height),
            Double(scrollIndex[ObjectIdentifier(scroll)] ?? -1),
        ])
    }

    private func write(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record) else {
            FileHandle.standardError.write(Data("scroll lab: unencodable record \(record["kind"] ?? "?")\n".utf8))
            return
        }
        output.write(data)
        output.write(Data("\n".utf8))
    }

    // MARK: - Finding the transcript

    /// The transcript's scroll view, the one in front.
    ///
    /// In a revision with a table only `TranscriptScrollView` qualifies: while a column holds for
    /// an arrival it answers no hit test, and anything else picked then (the inspector's file
    /// list, measured) stayed picked. Before the table, SwiftUI's own scroll view has no name of
    /// its own, so it is the one covering at least a third of the window, right of the sidebar.
    private func resolveScrollView() {
        if let scroll, scroll.window != nil, isTranscript(scroll), isPresented(scroll), isFrontmost(scroll) { return }
        guard let content = window?.contentView else { return }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let candidate = view as? NSScrollView { found.append(candidate) }
            view.subviews.forEach(walk)
        }
        walk(content)
        isTableRevision = isTableRevision || found.contains(where: Self.isTable)
        scroll = found.filter { isTranscript($0) && isPresented($0) && isFrontmost($0) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let scroll, scrollIndex[ObjectIdentifier(scroll)] == nil {
            scrollIndex[ObjectIdentifier(scroll)] = scrollIndex.count
        }
    }

    private var isTableRevision = false

    private static func isTable(_ view: NSScrollView) -> Bool {
        String(describing: type(of: view)) == "TranscriptScrollView"
    }

    private func isTranscript(_ candidate: NSScrollView) -> Bool {
        if Self.isTable(candidate) { return true }
        guard !isTableRevision, let content = window?.contentView else { return false }
        let frame = candidate.convert(candidate.bounds, to: nil)
        return frame.minX > 120 && frame.width * frame.height >= content.bounds.width * content.bounds.height / 3
    }

    /// Whether a click at the middle of this scroll view would land in it. A column kept alive for
    /// another workspace is neither hidden nor transparent, it is only underneath, so this is the
    /// question that tells it from the one being read.
    private func isFrontmost(_ candidate: NSScrollView) -> Bool {
        guard let content = window?.contentView else { return false }
        let centre = candidate.convert(CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY), to: nil)
        guard let hit = content.hitTest(content.convert(centre, from: nil)) else { return false }
        return hit === candidate || hit.isDescendant(of: candidate)
    }

    /// A pane kept alive for another workspace is still in the hierarchy, faded or held off screen.
    private func isPresented(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.isHidden || node.alphaValue < 0.01 { return false }
            current = node.superview
        }
        return true
    }

    // MARK: - Steps

    private func perform(_ step: [String: Any], index: Int) async {
        let kind = step["kind"] as? String ?? "?"
        let firstFrame = frames.count
        let firstRootRelayout = ScrollLabRootRelayouts.count
        let began = now()
        var result: [String: Any] = [:]
        FileHandle.standardError.write(Data("scroll lab: step \(index) \(kind) \(step["label"] ?? "")\n".utf8))
        switch kind {
        case "select": result = await select(step)
        case "rest": result = await rest(milliseconds(step["ms"], or: 1500))
        case "wheel", "trackpad": result = await gesture(step)
        case "resize": result = await resize(step)
        case "capture": result = await capture(step)
        case "jump": result = await jump()
        case "drift": result = await drift(step)
        case "append": result = startAppending(step)
        case "appendStop":
            // Waited for, so a row already on its way does not land in the rest that follows.
            appending?.cancel()
            await appending?.value
            appending = nil
        default: result = ["error": "unknown step \(kind)"]
        }
        resolveScrollView()
        var record: [String: Any] = [
            "kind": "step", "index": index, "step": step, "t0": began, "t1": now(),
            "frames": Array(frames[firstFrame...]), "result": result,
            "rootRelayouts": ScrollLabRootRelayouts.count - firstRootRelayout,
        ]
        record["place"] = place()
        write(record)
    }

    private func milliseconds(_ value: Any?, or fallback: Int) -> Int {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? fallback
    }

    private func place() -> [String: Any] {
        guard let scroll else { return ["found": false] }
        let origin = Double(scroll.contentView.bounds.origin.y)
        let document = Double(scroll.documentView?.frame.height ?? 0)
        let viewport = Double(scroll.contentView.bounds.height)
        var place: [String: Any] = [
            "found": true, "origin": origin, "document": document, "viewport": viewport,
            "fromEnd": document - viewport - origin, "class": String(describing: type(of: scroll)),
        ]
        if let table = scroll.documentView as? NSTableView { place["table"] = tableFacts(table, scroll: scroll) }
        place["hit"] = hitChain(at: scroll)
        return place
    }

    /// The classes under the middle of the scroll view, innermost first: what a click there reaches.
    private func hitChain(at view: NSView) -> [String] {
        guard let content = window?.contentView else { return [] }
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var chain: [String] = []
        var current = content.hitTest(content.convert(centre, from: nil))
        while let node = current, chain.count < 8 {
            chain.append(String(describing: type(of: node)))
            current = node.superview
        }
        return chain
    }

    /// What a table says about the rows it shows: how many, where the last one ends against the
    /// document, and how much of the viewport no row view covers.
    private func tableFacts(_ table: NSTableView, scroll: NSScrollView) -> [String: Any] {
        let rows = table.numberOfRows
        let visible = scroll.contentView.bounds
        let range = table.rows(in: visible)
        var covered: CGFloat = 0
        var missing = 0
        for row in range.location..<(range.location + range.length) {
            guard let view = table.rowView(atRow: row, makeIfNecessary: false) else {
                missing += 1
                continue
            }
            covered += view.frame.intersection(visible).height
        }
        let lastMaxY = rows > 0 ? Double(table.rect(ofRow: rows - 1).maxY) : 0
        return [
            "rows": rows, "firstVisible": range.location, "visibleCount": range.length,
            "lastRowMaxY": lastMaxY, "missingRowViews": missing,
            "uncovered": Double(max(0, min(visible.height, table.frame.height) - covered)),
        ]
    }

    // MARK: - Selection

    private func select(_ step: [String: Any]) async -> [String: Any] {
        guard let app else { return ["error": "no app"] }
        let previous = scroll
        let previousDocument = scroll?.documentView?.frame.height
        let requested = now()
        // In the same update as the selection, as a workspace whose inspector shows does.
        if let inspector = step["inspector"] as? Bool { app.isInspectorVisible = inspector }
        if let workspace = step["workspace"] as? String {
            app.selection = .workspace(WorkspaceID(workspace))
            if let session = step["session"] as? String {
                for _ in 0..<100 where app.selectedModel?.workspace.id.rawValue != workspace {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                app.selectedModel?.activeSessionID = SessionID(session)
            }
        }
        scroll = nil
        // The outgoing transcript can stay presented for a few frames and would look settled.
        for _ in 0..<60 {
            resolveScrollView()
            if let scroll, scroll !== previous || scroll.documentView?.frame.height != previousDocument { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let settled = await settle(timeout: milliseconds(step["timeoutMs"], or: 20000))
        return ["requestedAt": requested, "settledAt": settled.at, "stable": settled.stable, "shifts": settled.shifts,
                "selected": app.selectedModel?.workspace.id.rawValue ?? "",
                "session": app.selectedModel?.activeSessionID?.rawValue ?? ""]
    }

    /// Waits for the transcript to exist and then to stop moving: origin and document still for
    /// `quiet` milliseconds. The frames keep every move on the way, which is what the analysis
    /// counts as a jump after arrival.
    ///
    /// Every other pass also compares what is drawn with the pass before: a page that slides
    /// under the reader while the origin compensates for it is invisible to the numbers above
    /// and is exactly what "it jumps when I open a conversation" describes.
    private func settle(timeout: Int, quiet: Int = 700) async -> (at: Double, stable: Bool, shifts: [[Double]]) {
        let deadline = now() + Double(timeout) / 1000
        var lastChange = now()
        var last: (Double, Double) = (-1, -1)
        var shifts: [[Double]] = []
        var previous: (scroll: NSScrollView, rows: [[Double]])?
        var pass = 0
        while now() < deadline {
            resolveScrollView()
            pass += 1
            // From the first pass: a turn footer's file chips land within a tenth of a second of
            // the first draw, which a capture starting on the second pass never saw.
            if pass % 2 == 1, let scroll, let rows = signature() {
                if let previous, previous.scroll === scroll {
                    let found = compare(previous.rows, rows)
                    shifts.append([now(), Double(found["shift"] as? Int ?? 0), found["residue"] as? Double ?? -1,
                                   found["stillResidue"] as? Double ?? -1])
                }
                previous = (scroll, rows)
            }
            if let scroll {
                let current = (Double(scroll.contentView.bounds.origin.y), Double(scroll.documentView?.frame.height ?? 0))
                if abs(current.0 - last.0) > 0.5 || abs(current.1 - last.1) > 0.5 {
                    lastChange = now()
                    last = current
                } else if now() - lastChange > Double(quiet) / 1000 {
                    return (lastChange, true, shifts)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (lastChange, false, shifts)
    }

    private func rest(_ duration: Int) async -> [String: Any] {
        resolveScrollView()
        let anchor = Anchor(scroll: scroll)
        try? await Task.sleep(for: .milliseconds(min(300, duration)))
        let early = signature()
        try? await Task.sleep(for: .milliseconds(max(0, duration - 300)))
        let late = signature()
        var result: [String: Any] = ["anchorDrift": jsonNumber(anchor?.drift(in: scroll))]
        if let early, let late { result["pixels"] = compare(early, late) }
        if let late { result["blank"] = blankRuns(late) }
        return result
    }

    // MARK: - Gestures

    /// Wheel and trackpad, through the view under the pointer as a hand would reach it.
    ///
    /// `wheel` is a mouse: line deltas, no phases, so AppKit applies its own smoothing.
    /// `trackpad` is flicks with phases; see `flick` for why the momentum is a decaying tail.
    private func gesture(_ step: [String: Any]) async -> [String: Any] {
        resolveScrollView()
        guard scroll != nil else { return ["error": "no transcript"] }
        let up = (step["direction"] as? String ?? "up") == "up"
        let until = step["until"] as? String ?? "edge"
        let timeout = Double(milliseconds(step["timeoutMs"], or: 60000)) / 1000
        let deadline = now() + timeout
        var events: [[Double]] = []
        var anchor = Anchor(scroll: scroll)
        var reachedAt: Double?
        var sent = 0
        let limit = milliseconds(step["count"], or: .max)

        func send(_ delta: Double, phase: Int64, momentum: Int64, lines: Bool) {
            guard let scroll else { return }
            let before = Double(scroll.contentView.bounds.origin.y)
            let document = Double(scroll.documentView?.frame.height ?? 0)
            // The anchor taken before the previous event, read again now: how far its row moved
            // in the document between the two. Taken afresh before this one.
            let drift = anchor?.drift(in: scroll) ?? .nan
            anchor = Anchor(scroll: scroll)
            let delivered = deliver(delta: up ? delta : -delta, phase: phase, momentum: momentum, lines: lines)
            let after = Double(scroll.contentView.bounds.origin.y)
            // [t, requested, precise, origin before, origin after, anchor drift, document, phase, momentum,
            // table rows]: the rows tell an entry change from a height correction.
            let rows = (scroll.documentView as? NSTableView)?.numberOfRows ?? -1
            events.append([now(), delivered.delta, delivered.precise ? 1 : 0, before, after,
                           drift.isFinite ? drift : Self.missing, document, Double(phase), Double(momentum),
                           Double(rows)])
            sent += 1
        }

        func reached() -> Bool {
            guard let scroll else { return false }
            if until == "count" { return sent >= limit }
            if let fraction = step["fraction"] as? Double {
                let range = max(1, scroll.labEndOffset)
                let position = Double(scroll.contentView.bounds.origin.y / range)
                return up ? position <= fraction : position >= fraction
            }
            return up ? scroll.contentView.bounds.origin.y <= 0.5 : scroll.labDistanceFromEnd <= 1
        }

        let isTrackpad = (step["kind"] as? String) == "trackpad"
        let hold = milliseconds(step["holdMs"], or: 1500)
        while now() < deadline {
            resolveScrollView()
            if isTrackpad {
                await flick(step, send: send)
            } else {
                for _ in 0..<milliseconds(step["burst"], or: 1) {
                    send(step["lines"] as? Double ?? 1, phase: 0, momentum: 0, lines: true)
                }
                try? await Task.sleep(for: .milliseconds(milliseconds(step["intervalMs"], or: 100)))
            }
            guard reached() else { continue }
            guard until == "edge" else {
                reachedAt = now()
                break
            }
            // An edge counts once the hand has let go and nothing moved: history that lands above
            // the top after the gesture is a top that was not the first row.
            let document = scroll?.documentView?.frame.height ?? 0
            try? await Task.sleep(for: .milliseconds(hold))
            resolveScrollView()
            if reached(), abs((scroll?.documentView?.frame.height ?? 0) - document) < 0.5 {
                reachedAt = now()
                break
            }
        }
        return ["events": events, "reachedAt": reachedAt ?? NSNull(), "timedOut": now() >= deadline,
                "atTop": (scroll?.contentView.bounds.origin.y ?? 1) <= 0.5,
                "atEnd": (scroll?.labDistanceFromEnd ?? 1) <= 1]
    }

    /// One trackpad flick: a few phased moves, then a decaying tail over `momentumMs`, then the end.
    ///
    /// **The tail is the finger's, not momentum's.** Momentum phase events handed to the view are
    /// ignored by `NSScrollView`, measured: thirty of them moved the origin by nothing. What the
    /// app reacts to is the live scroll notifications, which a tail before `ended` places exactly
    /// where momentum would: `willStart` on the first move, `didEnd` after the last.
    private func flick(
        _ step: [String: Any],
        send: (Double, Int64, Int64, Bool) -> Void
    ) async {
        let frameGap = 1000.0 / 120
        let moves = milliseconds(step["flickFrames"], or: 6)
        let points = step["flickPoints"] as? Double ?? 30
        for index in 0..<moves {
            send(points, index == 0 ? 1 : 2, 0, false)
            try? await Task.sleep(for: .milliseconds(Int(frameGap)))
        }
        let tail = Double(milliseconds(step["momentumMs"], or: 600))
        var elapsed = 0.0
        var velocity = points * 0.92
        while elapsed < tail, velocity > 0.5 {
            send(velocity, 2, 0, false)
            velocity *= 0.92
            elapsed += frameGap
            try? await Task.sleep(for: .milliseconds(Int(frameGap)))
        }
        send(0, 4, 0, false)
        try? await Task.sleep(for: .milliseconds(milliseconds(step["pauseMs"], or: 120)))
    }

    /// Builds a scroll event and hands it to the deepest view under the centre of the transcript,
    /// which forwards it as it would a real one. Returns the points the event asked for.
    private func deliver(delta: Double, phase: Int64, momentum: Int64, lines: Bool) -> (delta: Double, precise: Bool) {
        guard let scroll, let window, let content = window.contentView,
              let event = CGEvent(
                  scrollWheelEvent2Source: nil, units: lines ? .line : .pixel,
                  wheelCount: 1, wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0
              ) else { return (0, false) }
        if !lines {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let centre = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: centre)
        let height = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: screen.x, y: height - screen.y)
        guard let nsEvent = NSEvent(cgEvent: event) else { return (0, false) }
        let target = content.hitTest(content.convert(centre, from: nil)) ?? scroll
        target.scrollWheel(with: nsEvent)
        return (Double(nsEvent.scrollingDeltaY), nsEvent.hasPreciseScrollingDeltas)
    }

    // MARK: - Jumping to the newest row

    /// What the "Jump to newest" pill does when pressed: the button is nothing but this call, in
    /// every revision compared.
    private func jump() async -> [String: Any] {
        guard let transcript = app?.selectedModel?.activeTranscript else { return ["error": "no transcript"] }
        transcript.jumpToLiveEnd()
        let settled = await settle(timeout: 8000)
        return ["pressed": true, "settledAt": settled.at, "stable": settled.stable, "shifts": settled.shifts,
                "atEnd": (scroll?.labDistanceFromEnd ?? 1) <= 1]
    }

    /// The view moved by the program a few points a frame, with no event at all, so a cost that
    /// follows the content moving can be told from one that follows the events.
    private func drift(_ step: [String: Any]) async -> [String: Any] {
        guard let scroll else { return ["error": "no scroll view"] }
        let points = step["points"] as? Double ?? 8
        for _ in 0..<milliseconds(step["frames"], or: 240) {
            let clip = scroll.contentView
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.origin.y - points)))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(8))
        }
        return [:]
    }

    // MARK: - Window size, capture, rows arriving

    private func resize(_ step: [String: Any]) async -> [String: Any] {
        guard let window else { return [:] }
        let width = step["width"] as? Double ?? Double(size.width)
        let height = step["height"] as? Double ?? Double(size.height)
        let anchor = Anchor(scroll: scroll)
        let before = signature()
        window.setFrame(CGRect(x: 0, y: 0, width: width, height: height), display: true)
        size = CGSize(width: width, height: height)
        let settled = await settle(timeout: 5000)
        var result: [String: Any] = ["anchorDrift": jsonNumber(anchor?.drift(in: scroll)), "shifts": settled.shifts]
        if let before, let after = signature() { result["pixels"] = compare(before, after) }
        return result
    }

    private func capture(_ step: [String: Any]) async -> [String: Any] {
        resolveScrollView()
        // At the scale a Retina reader sees. At 1x a text view 0.06 pt from where it was rounds to
        // another row of pixels, and a page back exactly where it was read as having moved.
        guard let current = signature(scale: 2) else { return ["error": "no capture"] }
        var result: [String: Any] = ["blank": blankRuns(current)]
        if let label = step["label"] as? String { captures[label] = current }
        if let path = step["windowPng"] as? String, let layer = window?.contentView?.layer,
           let size = window?.contentView?.bounds.size,
           let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            if window?.contentView?.isFlipped == true {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
        }
        if let path = step["png"] as? String, let image = render(scale: 1) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
        if let other = (step["compareTo"] as? String).flatMap({ captures[$0] }) {
            result["pixels"] = compare(other, current)
        }
        if let tokens = step["ocr"] as? [String] { result["ocr"] = recognise(tokens) }
        return result
    }

    private func startAppending(_ step: [String: Any]) -> [String: Any] {
        guard let store = app?.store, let session = step["session"] as? String else { return ["error": "no store"] }
        let interval = milliseconds(step["intervalMs"], or: 400)
        let startSeq = milliseconds(step["startSeq"], or: 1_000_000)
        appending?.cancel()
        appending = Task { @MainActor in
            var seq = startSeq
            var count = 0
            while !Task.isCancelled {
                count += 1
                for (kind, payload, ref) in Self.liveRows(count) {
                    seq += 1
                    _ = try? await store.append(Message(
                        sessionID: SessionID(session), seq: seq, kind: kind, payload: Data(payload.utf8), refID: ref
                    ))
                }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
        return ["startSeq": startSeq]
    }

    private static func liveRows(_ count: Int) -> [(MessageKind, String, String?)] {
        let id = "toolu_lablive\(count)"
        let text = "Live line \(count). " + String(repeating: "Streaming synthetic words. ", count: 1 + count % 7)
        return [
            (.toolUse, #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"echo lab \#(count)","description":"Synthetic command"}}]},"parent_tool_use_id":null}"#, id),
            (.toolResult, #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"lab \#(count)","is_error":false}]},"parent_tool_use_id":null}"#, id),
            (.assistantText, #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"parent_tool_use_id":null}"#, nil),
        ]
    }

    // MARK: - Pixels

    /// The visible transcript, drawn in process from the clip view's layers over a flat grey, so
    /// rows that draw nothing read as one colour whatever the pane behind them paints.
    private func render(scale: Int) -> CGImage? {
        guard let scroll, let layer = scroll.contentView.layer else { return nil }
        let bounds = scroll.contentView.bounds
        let width = Int(bounds.width) * scale, height = Int(bounds.height) * scale
        guard width > 8, height > 8,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if scroll.contentView.isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        layer.render(in: context)
        return context.makeImage()
    }

    /// One point per row of pixels, top down: the share of the row that is background and the
    /// mean brightness of eight vertical bands. Small enough to keep, rich enough to tell a still
    /// page from one that slid two points.
    private func signature(scale: Int = 1) -> [[Double]]? {
        guard let image = render(scale: scale), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = image.width, height = image.height, stride = image.bytesPerRow
        let background = dominantColour(bytes, width: width, height: height, stride: stride)
        var rows: [[Double]] = []
        rows.reserveCapacity(height)
        let bands = 8
        for row in 0..<height {
            var backgroundCount = 0
            var sums = [Double](repeating: 0, count: bands)
            for column in 0..<width {
                let offset = row * stride + column * 4
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                if abs(red - background.0) + abs(green - background.1) + abs(blue - background.2) < 12 {
                    backgroundCount += 1
                }
                sums[column * bands / width] += Double(red + green + blue) / 765
            }
            let bandWidth = Double(width) / Double(bands)
            rows.append([Double(backgroundCount) / Double(width)] + sums.map { $0 / bandWidth })
        }
        guard scale > 1 else { return rows }
        // Back to one row per point, so captures compare with the same slides and thresholds.
        return Swift.stride(from: 0, to: rows.count - scale + 1, by: scale).map { start in
            let group = rows[start..<(start + scale)]
            return group[start].indices.map { column in group.reduce(0) { $0 + $1[column] } / Double(scale) }
        }
    }

    private func dominantColour(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> (Int, Int, Int) {
        var counts: [Int: Int] = [:]
        let step = max(1, (width * height) / 20000)
        for index in Swift.stride(from: 0, to: width * height, by: step) {
            let offset = (index / width) * stride + (index % width) * 4
            let key = (Int(pixels[offset]) >> 3) << 10 | (Int(pixels[offset + 1]) >> 3) << 5 | Int(pixels[offset + 2]) >> 3
            counts[key, default: 0] += 1
        }
        let key = counts.max { $0.value < $1.value }?.key ?? 0
        return (((key >> 10) & 31) << 3 + 4, ((key >> 5) & 31) << 3 + 4, (key & 31) << 3 + 4)
    }

    /// The vertical slide between two captures that best explains the second, and how well it
    /// explains it. A slide of zero with a small residue is a page that held still.
    private func compare(_ first: [[Double]], _ second: [[Double]]) -> [String: Any] {
        let height = min(first.count, second.count)
        let reach = min(400, height / 2)
        func difference(_ shift: Int) -> Double {
            var total = 0.0
            var counted = 0
            for row in max(0, -shift)..<min(height, height - shift) {
                let a = first[row], b = second[row + shift]
                if a[0] > 0.995, b[0] > 0.995 { continue }
                for band in 1..<a.count { total += abs(a[band] - b[band]) }
                counted += 1
            }
            return counted < 20 ? .infinity : total / Double(counted)
        }
        var best = (shift: 0, residue: difference(0))
        for shift in -reach...reach where shift != 0 {
            let residue = difference(shift)
            if residue < best.residue { best = (shift, residue) }
        }
        let still = difference(0)
        return ["shift": best.shift, "residue": best.residue.isFinite ? best.residue : -1,
                "stillResidue": still.isFinite ? still : -1]
    }

    /// The longest run of rows that are nothing but background, and the run at the bottom, in
    /// points. A transcript at its end with a tall empty band under the last message is the
    /// complaint this was written for.
    private func blankRuns(_ rows: [[Double]]) -> [String: Any] {
        var longest = 0, current = 0, top = 0
        var seenContent = false
        for row in rows {
            if row[0] > 0.995 {
                current += 1
            } else {
                if !seenContent { top = current }
                seenContent = true
                current = 0
            }
            longest = max(longest, current)
        }
        return ["longest": longest, "bottom": current, "top": seenContent ? top : rows.count,
                "content": seenContent, "height": rows.count]
    }

    /// Whether the given words are on screen, read by Vision from a render of the visible rows.
    private func recognise(_ tokens: [String]) -> [String: Bool] {
        guard let image = render(scale: 2) else { return [:] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return Dictionary(uniqueKeysWithValues: tokens.map { ($0, text.contains($0)) })
    }

    /// Where an event had no anchor to measure: a revision without a table, or a row recycled.
    private static let missing = -1e9

    private func jsonNumber(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }

    private var configuration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }
}

/// The row view under the middle of the viewport, and where it stood in the document.
///
/// Read again later, the difference is how far the content moved under the reader without the
/// clip view moving: a row above changing height with nothing compensating, or compensation with
/// nothing to compensate for. Tables only; a SwiftUI `ScrollView` has no row views to hold.
@MainActor
private struct Anchor {
    let view: NSView
    let documentY: CGFloat

    init?(scroll: NSScrollView?) {
        guard let scroll, let table = scroll.documentView as? NSTableView else { return nil }
        let visible = scroll.contentView.bounds
        let row = table.row(at: CGPoint(x: visible.midX, y: visible.midY))
        guard row >= 0, let view = table.rowView(atRow: row, makeIfNecessary: false) else { return nil }
        self.view = view
        documentY = view.frame.minY
    }

    func drift(in scroll: NSScrollView?) -> Double {
        guard let table = scroll?.documentView as? NSTableView, view.superview === table else { return .nan }
        return Double(view.frame.minY - documentY)
    }
}

private extension NSScrollView {
    var labEndOffset: CGFloat { max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height) }
    var labDistanceFromEnd: CGFloat { labEndOffset - contentView.bounds.origin.y }
}
