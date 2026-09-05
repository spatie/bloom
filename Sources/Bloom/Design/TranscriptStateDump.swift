import AppKit
import BloomCore
import Foundation

/// **Everything the transcript believes about itself, written to a file, at the moment it is
/// wrong.**
///
/// # Why this ships rather than living in a probe
///
/// The blank transcript has now been chased for a night and fixed three times, and every one of
/// those fixes was reasoned from a mechanism caught under instrumentation rather than from a
/// reading taken while the app was actually broken. The owner can reproduce it on demand and we
/// could not read anything at the moment it happened, because every counter in this app is read
/// by a probe, and a probe is a launch flag that ends in `exit(0)`.
///
/// So the same reading the probe takes is taken here, from a live app, by two triggers:
///
/// - **`tripIfBlank`, which needs nobody.** The transcript's settle already knows how many rows
///   the table has and how many of them are on screen. Rows in the table and none in the viewport,
///   with no hold on and a pane that has a height, is a blank transcript, and it writes one file.
///   That is the whole condition: **a healthy pane writes nothing, logs nothing and costs two
///   integer comparisons on a path that already runs.**
/// - **`listen`, for the states that are wrong but not blank.** `kill -USR1` on the process writes
///   the same file.
///
/// # What it is for reading
///
/// The geometry says where the viewport is against the document, the counters say what the
/// transcript has been told about its own rows, and the row table says what the cache and the
/// table each believe about the rows near the screen. Between them:
///
/// - `isBlank` with the clip past `endOffset` is a viewport parked below the last row.
/// - `isBlank` with rows present and the clip inside the document is rows drawn at heights that
///   show nothing, and the row table names them.
/// - `scrollAlpha` at nought, or `scrollIsFrozen`, is `TranscriptHoldView` holding something it
///   should have let go of.
/// - **`cacheWidth` against `viewportWidth` is the one to check first, and it accuses a change of
///   ours.** `TranscriptRowHeights.isEvidence` refuses a height reported at a width the cache is
///   not for. That is right when the cache's width is right. If the cache is ever for a width the
///   pane is not, the same rule refuses EVERY report, nothing is ever measured, and the whole
///   transcript is drawn from estimates, which is whiter than a few bad heights ever made it.
///   `screenEstimated` and `widthMismatches` say whether that is what happened. A guard that can
///   cause the fault it was written for is a suspect in its own instrument, and it is named here
///   so a reader does not have to know the history to suspect it.
///
/// # What it must never do
///
/// It ships in the app the owner works in, so: nothing on a healthy pane, nothing that can run
/// away, and nothing under `~/Library/Application Support/Bloom/`. The automatic trip is capped at
/// `mostTrips` files for the life of the process; a signal is a person asking and is not capped.
/// Writing is synchronous on the main thread, which is a few milliseconds of a pane that is
/// already broken, at most a handful of times.
@MainActor
enum TranscriptStateDump {
    /// The four things a reading is taken from, gathered once so no part of it can pick up a
    /// different transcript from another part.
    struct Pane {
        var scroll: NSScrollView
        var hold: TranscriptHoldView
        var table: NSTableView?
        var coordinator: TranscriptTable.Coordinator?
    }

    /// How many rows either side of the screen the row table covers, for a live reading.
    ///
    /// Small on purpose. `ComposerProbe` takes 400 either side and writes 600KB, which is right
    /// for a file somebody opens in a script and wrong for one somebody reads. The rows near the
    /// screen are the ones that can explain what is on it.
    static let liveBand = 60

    /// How many files the automatic trip may write in the life of one process.
    ///
    /// A blank pane persists across many settles, and a trip per settle would be a file per 150
    /// milliseconds. Three readings of the same fault are two more than anybody needs.
    static let mostTrips = 3

    private static var trips = 0
    private static var signalSource: DispatchSourceSignal?

    // MARK: - The automatic trip

    /// **A transcript with rows in it and none of them on screen, once it has stopped moving.**
    ///
    /// Called from the settle, which is where the view has been still for 150ms, so a pane mid
    /// scroll or mid drag never reaches here. Three things are excluded because each is a blank
    /// pane that is not a fault: a table with no rows is an empty conversation, a hold is
    /// `TranscriptHoldView` deliberately drawing nothing while a conversation arrives, and a
    /// viewport with no height is a pane nobody has laid out.
    static func tripIfBlank(_ pane: Pane) {
        guard trips < mostTrips else { return }
        guard let table = pane.table, table.numberOfRows > 0 else { return }
        guard pane.hold.held == nil else { return }
        let clip = pane.scroll.contentView
        guard clip.bounds.height > 1 else { return }
        guard table.rows(in: clip.documentVisibleRect).length == 0 else { return }
        trips += 1
        write(pane, reason: "blank", band: liveBand)
    }

    // MARK: - The signal

    /// **`kill -USR1` writes the same reading, for a transcript that is wrong without being
    /// blank.**
    ///
    /// **The ignore goes in before the dispatch source, and the order is the whole of it.**
    /// `SIGUSR1`'s default disposition is to TERMINATE the process. A dispatch source does not
    /// change the disposition; it observes a signal the process has already been allowed to
    /// survive. Installed the other way round, the first `kill -USR1` kills the app the owner is
    /// working in, which is worse than the bug this exists to find.
    ///
    /// `SIG_IGN` rather than a C handler, because a signal handler may only call async-signal-safe
    /// functions and none of what this does is. The source is what does the work, on the main
    /// queue, on an ordinary turn.
    static func listen() {
        guard signalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard let pane = findInAnyWindow() else { return }
                write(pane, reason: "signal", band: liveBand)
            }
        }
        source.resume()
        signalSource = source
    }

    // MARK: - Writing it down

    /// The file every reading lands in, overwritten, so a reader always knows where to look.
    static let latestPath = NSTemporaryDirectory() + "bloom-transcript-state.json"

    /// **Two files: the latest, and a timestamped sibling.** The fixed name is what somebody types
    /// without being told; the sibling is so a second occurrence does not erase the first, which is
    /// exactly what happens when a fault repeats while somebody is reading the file it wrote.
    @discardableResult
    static func write(_ pane: Pane, reason: String, band: Int) -> String? {
        var report = state(of: pane, band: band)
        report["reason"] = .string(reason)
        report["takenAt"] = .string(ISO8601DateFormatter().string(from: .now))
        report["pid"] = .integer(Int(ProcessInfo.processInfo.processIdentifier))
        report["version"] = .string(
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        )
        report["build"] = .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        report["trips"] = .integer(trips)

        guard let data = try? JSONEncoder.sorted.encode(JSONValue.object(report)) else { return nil }
        try? data.write(to: URL(fileURLWithPath: latestPath))
        let stamped = NSTemporaryDirectory()
            + "bloom-transcript-state-\(Int(Date.now.timeIntervalSince1970)).json"
        try? data.write(to: URL(fileURLWithPath: stamped))
        return stamped
    }

    // MARK: - The reading itself

    /// Everything worth knowing about a transcript, in one object.
    ///
    /// `ComposerProbe` takes the same one, which is why it is here rather than there: two readings
    /// of the same thing that can disagree are worth less than one that cannot.
    static func state(of pane: Pane, band: Int) -> [String: JSONValue] {
        let clip = pane.scroll.contentView
        let offset = Double(clip.bounds.origin.y)
        let end = Double(pane.scroll.endOffset)
        let range = pane.table.map { $0.rows(in: clip.documentVisibleRect) }
        let count = pane.table?.numberOfRows ?? -1
        let visible = range?.length ?? -1
        let facts = rowFacts(pane, band: band)
        // **Not the three that redraw themselves.** The streaming tail and the bubble on its way
        // out draw nothing between turns and are measured on every pass, so counting them made
        // `lostRows` two before anything had gone wrong. `viewFor` exempts them from the silence
        // guard for the same reason, so nought is never held against one.
        let lost = facts.filter { $0.known == 0 && !$0.drawsNothing && !$0.redrawsItself }
        let guesses = facts.filter { $0.known == nil }.map(\.assumed)
        let measured = facts.compactMap(\.known)

        var out: [String: JSONValue] = [
            // Where the viewport is against the document. A positive `overshoot` is a viewport
            // below the last row, which is the state nothing in the transcript can recover from
            // on its own, because every recovery needs a row on screen to start from.
            "offset": .number(offset),
            "endOffset": .number(end),
            "overshoot": .number(offset - end),
            "contentHeight": .number(Double(pane.scroll.documentView?.frame.height ?? 0)),
            "viewportHeight": .number(Double(clip.bounds.height)),
            "viewportWidth": .number(Double(clip.bounds.width)),
            "scrollAlpha": .number(Double(pane.scroll.alphaValue)),
            "scrollFrame": rect(pane.scroll.frame),
            "holdBounds": rect(pane.hold.bounds),
            "held": .string(name(of: pane.hold.held)),
            // `frozen` is private to `TranscriptHoldView`, and this is the same question: a scroll
            // view sitting at anything other than its host's bounds is a frozen one.
            "scrollIsFrozen": .bool(pane.scroll.frame != pane.hold.bounds),
            // **The width the cache is for against the width the pane is.** See the head of this
            // file: these two disagreeing is the one way a change of ours could have caused what
            // it was written to stop.
            "cacheWidth": .number(pane.coordinator?.heightCacheWidth ?? 0),
            "cacheIsReady": .bool(pane.coordinator?.heightCacheIsReady ?? false),
            "cached": .integer(pane.coordinator?.heightCacheCount ?? -1),
            // What the transcript has been told about its own rows since this process started.
            "widthMismatches": .integer(TranscriptHoldCensus.widthMismatches),
            "silenced": .integer(TranscriptHoldCensus.silencedRows),
            "cellsBuilt": .integer(TranscriptHoldCensus.cellsBuilt),
            "screenEstimated": .integer(TranscriptHoldCensus.screenEstimated),
            "screenEstimatedSettled": .integer(TranscriptHoldCensus.screenEstimatedSettled),
            "screensSeen": .integer(TranscriptHoldCensus.screensSeen),
            "mismatches": .array(TranscriptHoldCensus.mismatches.map { json(of: $0) }),
            "silences": .array(TranscriptHoldCensus.silences.map { json(of: $0) }),
            "numberOfRows": .integer(count),
            "visibleRows": .integer(visible),
            "firstVisibleRow": .integer(range.map { $0.length > 0 ? $0.location : -1 } ?? -1),
            "rowViews": .integer(pane.table?.subviews.count ?? -1),
            "hostedRows": .integer(hostingViewCount(in: pane.table)),
            // Rows in the table and none of them in the viewport.
            "isBlank": .bool(count > 0 && visible == 0),
            // **What the document is actually made of.** The rows above the band are the ones
            // nobody has measured, so the points they are given divided by their number is the
            // estimate the transcript's whole length rests on.
            "rowsAboveBand": .integer(facts.first?.row ?? 0),
            "pointsAboveBand": .number(facts.first?.top ?? 0),
            "pointsPerRowAboveBand": .number(
                (facts.first?.row ?? 0) > 0
                    ? (facts.first?.top ?? 0) / Double(facts.first?.row ?? 1)
                    : 0
            ),
            // **The largest height ever handed to a row nobody has looked at.** It was 6,025 on
            // the old estimator, fourteen screens for content nobody had seen.
            "largestGuess": .number(guesses.max() ?? 0),
            // What the rows that HAVE been measured come to, per row, counting the ones that
            // measured nothing. The only truth here, and it is the truth about the band rather
            // than about the document.
            "measuredPointsPerRow": .number(
                measured.isEmpty ? 0 : measured.reduce(0, +) / Double(measured.count)
            ),
            "measuredRows": .integer(measured.count),
            "lostRows": .integer(lost.count),
            "bandRows": .integer(facts.count),
            "guessedRows": .integer(facts.filter { $0.known == nil && !$0.drawsNothing }.count),
            "cellsHeld": .integer(facts.filter(\.hasCell).count),
            "rows": .array(facts.map { json(of: $0) }),
        ]
        out["lost"] = .array(lost.prefix(40).map { json(of: $0) })
        return out
    }

    /// The rows either side of the ones on screen, which is where the explanation for a blank one
    /// is.
    private static func rowFacts(
        _ pane: Pane, band: Int
    ) -> [TranscriptTable.Coordinator.RowFact] {
        guard let coordinator = pane.coordinator else { return [] }
        let visible = coordinator.visibleRowRange
        let count = pane.table?.numberOfRows ?? 0
        // A visible range of nothing is the blank itself, so the band is taken from whatever row
        // is under the offset instead of from a range that has collapsed. `row(at:)` answers -1
        // for a point past the last row, which is the parking case, and the band then starts at
        // the end of the table.
        let middle: Int
        if visible.isEmpty {
            let under = pane.table?.row(
                at: NSPoint(x: 0, y: pane.scroll.contentView.bounds.origin.y)
            ) ?? -1
            middle = under >= 0 ? under : max(0, count - band)
        } else {
            middle = visible.lowerBound
        }
        let lower = max(0, middle - band)
        let upper = min(count, max(visible.upperBound, middle) + band)
        guard lower < upper else { return [] }
        return coordinator.rowFacts(for: lower..<upper)
    }

    // MARK: - Finding the transcript

    /// The transcript in whatever window has one, for a trigger that arrives from outside the app.
    ///
    /// By the hold view rather than by the tallest scroll view, because the hold view is the
    /// transcript's own and nothing else in the window is one. A window with two chats in it hands
    /// back the first found, which is a limitation worth knowing and not worth solving until a
    /// reading comes back from the wrong pane.
    static func findInAnyWindow() -> Pane? {
        for window in NSApp.windows {
            guard let content = window.contentView, let pane = find(in: content) else { continue }
            return pane
        }
        return nil
    }

    static func find(in root: NSView) -> Pane? {
        guard let hold = holdView(in: root) else { return nil }
        return Pane(
            scroll: hold.scroll,
            hold: hold,
            table: hold.scroll.documentView as? NSTableView,
            coordinator: hold.delegate as? TranscriptTable.Coordinator
        )
    }

    static func holdView(in root: NSView) -> TranscriptHoldView? {
        if let found = root as? TranscriptHoldView { return found }
        for subview in root.subviews {
            if let found = holdView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Saying it in JSON

    static func json(of fact: TranscriptTable.Coordinator.RowFact) -> JSONValue {
        .object([
            "row": .integer(fact.row),
            "entry": .string(fact.name),
            "shape": .string(fact.shape),
            "drawsNothing": .bool(fact.drawsNothing),
            "known": fact.known.map { JSONValue.number($0) } ?? .null,
            "assumed": .number(fact.assumed),
            "measuredNothing": .bool(fact.measuredNothing),
            "needsMeasuring": .bool(fact.needsMeasuring),
            "told": .number(fact.told),
            "top": .number(fact.top),
            "redrawsItself": .bool(fact.redrawsItself),
            "hasCell": .bool(fact.hasCell),
        ])
    }

    static func json(of mismatch: TranscriptHoldCensus.Mismatch) -> JSONValue {
        .object([
            "row": .integer(mismatch.row),
            "shape": .string(mismatch.shape),
            "reportedWidth": .number(mismatch.reportedWidth),
            "cacheWidth": .number(mismatch.cacheWidth),
            "columnWidth": .number(mismatch.columnWidth),
            "cellWidth": .number(mismatch.cellWidth),
            "reportedHeight": .number(mismatch.reportedHeight),
            "knownHeight": .number(mismatch.knownHeight),
        ])
    }

    static func json(of silence: TranscriptHoldCensus.Silence) -> JSONValue {
        .object([
            "row": .integer(silence.row),
            "source": .string(silence.source),
            "shape": .string(silence.shape),
            "columnWidth": .number(silence.columnWidth),
            "viewportWidth": .number(silence.viewportWidth),
            "viewportHeight": .number(silence.viewportHeight),
        ])
    }

    static func name(of held: TranscriptHoldView.Held?) -> String {
        guard let held else { return "none" }
        switch held {
        case .nothing: return "nothing"
        case .whatIsDrawn: return "whatIsDrawn"
        }
    }

    static func rect(_ rect: CGRect) -> JSONValue {
        .object([
            "x": .number(Double(rect.origin.x)), "y": .number(Double(rect.origin.y)),
            "w": .number(Double(rect.width)), "h": .number(Double(rect.height)),
        ])
    }

    /// How many views under the table are hosting a SwiftUI graph, which is the number the reload
    /// teardown is quadratic in. By class name, because `NSHostingView` is generic.
    static func hostingViewCount(in table: NSTableView?) -> Int {
        guard let table else { return -1 }
        var found = 0
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).hasPrefix("NSHostingView") { found += 1 }
            for subview in view.subviews { walk(subview) }
        }
        walk(table)
        return found
    }
}

private extension JSONEncoder {
    /// Sorted keys, so two readings of the same fault can be diffed against each other.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
