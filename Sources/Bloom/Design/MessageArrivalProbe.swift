import AppKit
import BloomCore
import SwiftUI

/// Samples only its own offscreen hosting view. Checks that the real drawing fades, that a new
/// hosting view continues the same arrival, and that the effect never changes the row's size.
@MainActor
enum MessageArrivalProbe {
    private static let harness = ProbeHarness(subject: "message-arrival")
    static var isRequested: Bool { harness.isRequested }

    static func schedule() { Task { @MainActor in await run() } }

    private static func run() async {
        _ = await harness.window()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [], backing: .buffered, defer: false
        )
        let arrival = MessageArrival(style: .sent)
        func host(_ ticket: MessageArrival?) -> NSView {
            NSHostingView(rootView: Color.red.frame(width: 120, height: 40)
                .messageArrival(ticket).padding(20).background(Color.white))
        }
        func sample(_ view: NSView) -> Double {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return Double(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)?.greenComponent ?? -1)
        }
        let first = host(arrival)
        window.contentView = first
        window.layoutIfNeeded()
        let size = first.fittingSize
        let beginning = sample(first)
        try? await Task.sleep(for: .milliseconds(80))
        let middle = sample(first)
        let saved = host(arrival)
        window.contentView = saved
        window.layoutIfNeeded()
        let handoff = sample(saved)
        try? await Task.sleep(for: .milliseconds(400))
        let end = sample(saved)
        let history = host(nil)
        window.contentView = history
        let baseline = sample(history)
        var failures: [String] = []
        if !(beginning > middle && middle > end && end >= 0) {
            failures.append("offscreen drawing did not expose intermediate fade frames")
        }
        if !(handoff <= middle + 0.1 && handoff >= end) {
            failures.append("saved row restarted or lost its arrival")
        }
        if size != saved.fittingSize { failures.append("arrival changed layout dimensions") }
        if abs(end - baseline) > 0.01 { failures.append("arrival did not settle at full opacity") }
        harness.write(.object([
            "passed": .bool(failures.isEmpty), "failures": .strings(failures),
            "greenSamples": .numbers([beginning, middle, handoff, end]),
            "baseline": .number(baseline),
            "stableSize": .bool(size == saved.fittingSize),
        ]))
        exit(failures.isEmpty ? 0 : 1)
    }
}
