import AppKit
import BloomCore
import QuartzCore
import Observation
import SwiftUI

#if DEBUG
/// Runs the table's instant-echo handoff and the real follower in a window that is never shown.
@MainActor
enum TranscriptSendProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--transcript-send-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    @Observable
    final class Activity {
        var label: String?
    }

    private struct ActivityRow: View {
        let activity: Activity
        var body: some View {
            if let label = activity.label {
                StreamingStatusView(glyph: nil, text: label)
                    .padding(.bottom, TranscriptLayout.block)
            } else {
                Color.clear.frame(height: 0)
            }
        }
    }

    private static func run() async {
        let controller = TranscriptTableController()
        let follower = TranscriptLiveEndFollower()
        follower.onStart = { controller.followerTookOver() }
        follower.onStop = { controller.followerHandedBack() }
        follower.onRest = { controller.goToEnd() }
        let environment = TranscriptRowEnvironment(
            app: AppModel(), hoverHost: TranscriptHoverHost(), bubbleWidth: TranscriptBubbleWidth(),
            linkActions: TranscriptLinkActions(), fontScale: 1, chatFont: .standard,
            lineHeight: .defaultChoice, reduceMotion: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        func entry(_ id: TranscriptEntryID, text: String, height: CGFloat) -> TranscriptTableEntry {
            TranscriptTableEntry(
                id: id,
                contentKey: TranscriptContentKey { $0.combine(id); $0.combine(text); $0.combine(height) },
                drawsNothing: height == 0,
                content: { AnyView(Text(text).frame(height: height)) }
            )
        }
        let activity = Activity()
        let isShort = CommandLine.arguments.contains("--short-transcript")
        var sentArrival: MessageArrival?
        func message(_ id: TranscriptEntryID, visible: Bool) -> TranscriptTableEntry {
            TranscriptTableEntry(
                id: id, contentKey: TranscriptContentKey { $0.combine(id); $0.combine(visible) },
                drawsNothing: !visible,
                sentArrival: visible ? sentArrival : nil,
                content: {
                    guard visible else { return AnyView(EmptyView()) }
                    return AnyView(
                        UserTurnRowView(text: "Analyse the work on this branch", home: TranscriptHome())
                            .padding(.horizontal, TranscriptLayout.inset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            )
        }
        let history = (0..<(isShort ? 2 : 25)).map { entry(.row($0), text: "Earlier message \($0)", height: 48) }
        func entries(phase: Int) -> [TranscriptTableEntry] {
            var rows = history
            // Sending already follows the completed turn. Its gap cannot wait for persistence.
            rows.append(entry(.row(100), text: "Completed", height: 24 + (phase > 0 ? TranscriptLayout.turnGap : TranscriptLayout.tight)))
            let held = TranscriptWindow(start: 0, end: 1)
            let visible = held.includingAppendedRows(previousCount: 1, rowCount: phase >= 2 ? 2 : 1)
            if visible.end == 2 { rows.append(message(.row(101), visible: true)) }
            let activityHeight = TranscriptLayout.rowHeight + TranscriptLayout.block
            if phase == 3 { rows.append(entry(.row(102), text: "Completed", height: activityHeight)) }
            rows.append(message(.sending, visible: phase == 1))
            let showsActivity = phase > 0 && phase < 3
            rows.append(TranscriptTableEntry(
                id: .streaming, contentKey: TranscriptContentKey { $0.combine("activity"); $0.combine(showsActivity) },
                minimumHeight: showsActivity ? activityHeight : 0,
                fixedHeight: phase == 3 ? 0 : nil,
                content: {
                    AnyView(ActivityRow(activity: activity)
                        .frame(minHeight: showsActivity ? activityHeight : 0))
                }
            ))
            rows.append(.bottomSpacing(clearance: 100))
            return rows
        }
        func root(phase: Int) -> TranscriptTable {
            TranscriptTable(
                entries: entries(phase: phase), session: SessionID("send-probe"), controller: controller,
                scale: 1, rowEnvironment: environment, onGeometryChange: { _ in }, onSettled: {},
                onLiveScrollChange: { follower.isPaused = $0 }, onContentWillChange: { follower.nudge() }
            )
        }
        let host = NSHostingView(rootView: root(phase: 0))
        window.contentView = host
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.arrived()
        controller.goToEnd()
        host.layoutSubtreeIfNeeded()
        follower.scrollView = controller.scrollView
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        guard let scroll = controller.scrollView else { exit(1) }
        let before = scroll.contentView.bounds.minY
        let oldHeight = scroll.documentView?.frame.height ?? 0
        sentArrival = MessageArrival(style: .sent)
        activity.label = "Starting"
        host.rootView = root(phase: 1)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(10))
        host.layoutSubtreeIfNeeded()
        let beginning = scroll.contentView.bounds.minY
        check(abs(beginning - before) <= 1, "send jumped to the new end before its first animation frame")
        check(follower.isFollowing, "follower did not take ownership before insertion")
        if let table = scroll.documentView as? NSTableView {
            let bubbleTop = table.rect(ofRow: history.count + 1).minY - beginning
            if isShort {
                let cell = table.view(atColumn: 0, row: history.count + 1, makeIfNecessary: false)
                let animation = cell?.subviews.first?.layer?.animation(forKey: TranscriptSentMotion.animationKey) as? CABasicAnimation
                let distance = abs((animation?.fromValue as? NSNumber)?.doubleValue ?? 0)
                check(distance > 0, "short conversation did not animate the bubble")
                check(abs(bubbleTop + distance - (scroll.contentView.bounds.height - 100 + ComposerLayout.textClearance)) <= 1,
                      "short conversation's bubble did not start behind the composer")
            } else {
                check(bubbleTop >= scroll.contentView.bounds.height - 100 - 1, "bubble did not begin behind the composer")
            }
        }
        var offsets: [Double] = [Double(beginning)]
        var heights: [Double] = []
        var rowHeights: [[Double]] = []
        var bubbleTops: [Double] = []
        for frame in 0..<70 {
            if frame == 8 {
                activity.label = "Working"
                host.rootView = root(phase: 2)
            }
            if frame == 40 {
                activity.label = nil
                host.rootView = root(phase: 3)
            }
            host.layoutSubtreeIfNeeded()
            follower.advance(at: CACurrentMediaTime())
            offsets.append(Double(scroll.contentView.bounds.minY))
            heights.append(Double(scroll.documentView?.frame.height ?? 0))
            if let table = scroll.documentView as? NSTableView {
                bubbleTops.append(table.rect(ofRow: history.count + 1).minY - scroll.contentView.bounds.minY)
                rowHeights.append((max(0, table.numberOfRows - 4)..<table.numberOfRows).map {
                    Double(table.rect(ofRow: $0).height)
                })
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        check(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "send or Working transition reversed the scroll")
        check(zip(bubbleTops, bubbleTops.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }, "saving pushed the message back towards the composer")
        if !isShort {
            check(offsets.filter { $0 > beginning + 1 && $0 < scroll.endOffset - 1 }.count > 5, "send had no intermediate scroll positions")
        }
        check(scroll.distanceFromEnd <= 1, "send did not settle at the live end")
        if isShort {
            check(abs((heights.last ?? 0) - Double(oldHeight)) <= 1, "short-chat animation unexpectedly resized the document")
        } else {
            check((heights.last ?? 0) > Double(oldHeight), "send did not add the message and activity line")
        }
        if let low = heights.min(), let high = heights.max() {
            check(high - low <= 1, "temporary and saved message handoff exposed a transient height")
        }
        check(!window.isVisible, "the probe displayed a window")
        follower.stop()
        let result: [String: Any] = [
            "checks": checks, "passed": failures.isEmpty, "failures": failures,
            "offsets": offsets, "documentHeights": heights, "rowHeights": rowHeights,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
