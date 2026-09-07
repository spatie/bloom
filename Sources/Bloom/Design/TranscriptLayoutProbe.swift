import AppKit
import BloomCore
import Observation
import SwiftUI

/// Exercises the real table and hosting views with deterministic rows. Unlike the core tests,
/// this checks both SwiftUI's measurements and the realised positions against AppKit's row
/// rectangles. Correct cached heights alone missed content drawn beyond the scrollable end.
/// Run in an isolated app with --transcript-layout-probe <report.json> --window-hidden.
@MainActor
enum TranscriptLayoutProbe {
    private static let harness = ProbeHarness(subject: "transcript-layout")
    static var isRequested: Bool { harness.isRequested }

    @Observable
    final class Tail {
        var height: CGFloat = 80
    }

    private struct TailRow: View {
        let tail: Tail
        var body: some View {
            Color.blue.frame(height: tail.height)
        }
    }

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        let (window, _) = await harness.window()
        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        let controller = TranscriptTableController()
        let tail = Tail()
        var entries = (0..<120).map { row in
            TranscriptTableEntry(
                id: .row(row), contentKey: TranscriptContentKey { $0.combine(row) },
                shape: .answer,
                content: {
                    AnyView(Text(String(repeating: "A transcript row that wraps when resized. ", count: row % 9 + 1))
                        .font(.system(size: 15)).padding(8))
                }
            )
        }
        entries.append(TranscriptTableEntry(
            id: .streaming, contentKey: TranscriptContentKey { $0.combine("tail") },
            content: { AnyView(TailRow(tail: tail)) }
        ))
        let view = TranscriptTable(
            entries: entries, session: SessionID("layout-probe"), controller: controller,
            scale: 1,
            rowEnvironment: TranscriptRowEnvironment(
                app: app, hoverHost: TranscriptHoverHost(), bubbleWidth: TranscriptBubbleWidth(),
                linkActions: TranscriptLinkActions(), fontScale: 1, chatFont: .standard,
                lineHeight: .standard, reduceMotion: true
            ),
            onGeometryChange: { _ in }, onSettled: {}, onLiveScrollChange: { _ in }
        )
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 600))
        await settle(window)
        controller.arrived()
        controller.goToEnd()
        await settle(window)

        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func checkRows(_ phase: String) {
            guard let hold = TranscriptStateDump.holdView(in: host),
                  let coordinator = hold.delegate as? TranscriptTable.Coordinator else {
                check(false, "\(phase): no table")
                return
            }
            let rows = coordinator.rowFacts(for: coordinator.visibleRowRange)
            check(!rows.isEmpty, "\(phase): blank viewport")
            check(rows.allSatisfy { row in
                guard let known = row.known else { return false }
                return abs(row.told - max(0.01, known)) <= 0.5
                    && (row.redrawsItself || !row.needsMeasuring)
            }, "\(phase): visible row has a gap, overlap or stale measurement")
            check(rows.allSatisfy { row in
                guard let top = row.drawnTop, let height = row.drawnHeight else { return true }
                return abs(top - row.top) <= 0.5 && abs(height - row.told) <= 0.5
            }, "\(phase): rendered cell disagrees with its scrollable row rectangle")
        }

        // The live report had correct cached heights but every realised row was 92 points
        // below rect(ofRow:). Reproduce that state explicitly: ordinary layout and notifying
        // the same row heights did not repair it in the running app.
        guard let scroll = controller.scrollView,
              let table = scroll.documentView as? NSTableView else { harness.fail("no scroll view") }
        table.enumerateAvailableRowViews { row, _ in
            row.setFrameOrigin(NSPoint(x: row.frame.minX, y: row.frame.minY + 92))
        }
        var displaced = false
        table.enumerateAvailableRowViews { row, index in
            if abs(row.frame.minY - table.rect(ofRow: index).minY) > 90 { displaced = true }
        }
        check(displaced, "failed to reproduce displaced row views")
        table.needsLayout = true
        table.layoutSubtreeIfNeeded()
        checkRows("after repairing displaced rows")

        guard let alignedTable = table as? TranscriptTableView else { harness.fail("no aligned table") }
        alignedTable.deferRowAlignment(for: 0.2)
        table.enumerateAvailableRowViews { row, _ in
            row.setFrameOrigin(NSPoint(x: row.frame.minX, y: row.frame.minY + 20))
        }
        alignedTable.alignRowOrigins()
        var keptAnimation = false
        table.enumerateAvailableRowViews { row, index in
            if abs(row.frame.minY - table.rect(ofRow: index).minY) > 19 { keptAnimation = true }
        }
        check(keptAnimation, "row repair interrupted a deliberate animation")
        await settle(window)
        checkRows("after animation")

        for height in [180.0, 420, 1, 300, 600] {
            window.setContentSize(NSSize(width: 640, height: height))
            await settle(window)
            if height > 1 {
                check(controller.geometry.isAtEnd, "height \(height): lost live end")
                checkRows("height \(height)")
            }
        }
        controller.scroll(to: .row(60), delta: 12)
        await settle(window)
        let place = controller.topmostPlace
        for height in [220.0, 560] {
            window.setContentSize(NSSize(width: 640, height: height))
            await settle(window)
            check(controller.topmostPlace?.seq == place?.seq, "reading resize: changed row")
            check(abs((controller.topmostPlace?.delta ?? 0) - (place?.delta ?? 0)) <= 1,
                  "reading resize: changed offset within row")
            checkRows("reading resize")
        }
        for width in [420.0, 900, 640] {
            window.setContentSize(NSSize(width: width, height: 560))
            await settle(window)
            checkRows("width \(width)")
        }

        controller.goToEnd()
        await settle(window)
        // Keep the gesture open while an already visible row changes size. The former queue
        // refused every height correction until didEndLiveScroll, leaving 180 points of blank.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for height in [260.0, 40] {
            tail.height = height
            await settle(window)
            check(abs(table.rect(ofRow: entries.count - 1).height - height) <= 0.5,
                  "live scroll: tail did not adopt height \(height)")
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await settle(window)
        controller.goToEnd()
        await settle(window)
        checkRows("after live scroll")
        harness.write(.object([
            "checks": .integer(checks), "passed": .bool(failures.isEmpty),
            "failures": .array(failures.map(JSONValue.string)),
        ]))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ window: NSWindow) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
    }
}
