import AppKit
import QuartzCore

/// Drives `SwitchTrace.tick` once per vsync, and records how long each frame took.
///
/// The frame intervals matter as much as the marks. A switch whose data is ready in 40ms and whose
/// next frame takes 700ms is not a slow database, it is a slow layout, and only the interval says
/// which of the two is being looked at.
///
/// Its own file because it has two probes reading it. It was `private` inside `SwitchProbe.swift`,
/// and `TabProbe` needs exactly the same clock: a second copy of a display link that measures the
/// main thread is two things to keep in step, and the whole point of a measurement is that two
/// runs of it are comparable.
@MainActor
final class Ticker {
    private var link: CADisplayLink?
    private let view: NSView
    private var last: CFTimeInterval = 0
    private(set) var intervalsMs: [Double] = []

    init(view: NSView) { self.view = view }

    func start() {
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Where each frame fell relative to the switch, and how long it took. The offsets are what
    /// turn a list of intervals into a picture of when the window was frozen.
    private(set) var blocksMs: [[Double]] = []
    private var origin: CFTimeInterval = 0

    /// Clears the frame record so each switch reports only its own frames.
    func beginRun() {
        intervalsMs.removeAll()
        blocksMs.removeAll()
        last = 0
        origin = CACurrentMediaTime()
    }

    @objc private func tick() {
        SwitchTrace.tick()
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last != 0 else { return }
        let interval = (now - last) * 1000
        intervalsMs.append(interval)
        // Only the frames that were late. A list of six hundred 8ms ticks says nothing, and the
        // ones over two frame times are exactly the moments the window stood still.
        if interval > 20 {
            blocksMs.append([(last - origin) * 1000, interval])
        }
    }
}
