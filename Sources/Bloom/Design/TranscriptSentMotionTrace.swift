#if DEBUG
import AppKit
import BloomCore
import QuartzCore

/// Screenshots arrive after a short send animation has finished. An opt-in display-link trace
/// records its actual presentation positions without capturing the screen or message contents.
@MainActor
enum TranscriptSentMotionTrace {
    static func record(content: NSView, cell: NSView, arrival: MessageArrival, distance: CGFloat) {
        guard FileManager.default.fileExists(atPath: "/tmp/bloom-record-sent-motion") else { return }
        var geometry: [[Double]] = []
        let recorder = FrameRecorder(view: content) { [weak content, weak cell] in
            guard let content, content.window != nil, let cell else { return .nan }
            let origin = cell.convert(NSPoint.zero, to: nil)
            if let scroll = cell.enclosingScrollView, let table = scroll.documentView as? NSTableView {
                let row = table.row(for: cell)
                geometry.append([
                    Date().timeIntervalSince1970, scroll.contentView.bounds.minY, table.frame.height,
                    Double(row), row >= 0 ? table.rect(ofRow: row).minY : -1,
                    origin.y, content.layer?.presentation()?.transform.m42 ?? 0,
                ])
            }
            return origin.y + (content.layer?.presentation()?.transform.m42 ?? 0)
        }
        let began = Date()
        recorder.start()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            recorder.stop()
            let values: [String: Any] = [
                "began": began.timeIntervalSince1970,
                "arrival": arrival.startedAt.timeIntervalSince1970,
                "distance": distance,
                "intervals": recorder.intervals,
                "positions": recorder.widths.map { $0.isFinite ? $0 as Any : NSNull() },
                "geometry": geometry,
            ]
            let url = URL(fileURLWithPath: "/tmp/bloom-sent-motion-\(UUID().uuidString).json")
            do {
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch {
                Log.composer.error("Could not save sent-message motion trace: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
