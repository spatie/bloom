import AppKit
import SwiftUI
import BloomCore

#if DEBUG
/// Whether a changing figure rolls or jumps, measured rather than looked at.
///
/// Written when the numeric content transition on `DiffStatLabel` and `CountLabel` shipped and
/// the owner could not see it move in the sidebar. A still shows nothing either way, so this draws
/// each fixture, changes its number, and renders the layer tree every few milliseconds across the
/// change. A frame that matches neither the first number nor the last is a frame of the roll;
/// none at all means the change landed in one step.
///
/// Two controls bracket it. A bare `Text` changed inside `withAnimation` has to report frames,
/// or the render cannot see animation at all; a bare `Text` changed with no animation has to
/// report none, or the count is measuring something other than the roll.
///
/// What it found, and why `AppModel.reload` animates its write. Every label rolls in a plain
/// stack, which is the inspector and the hover card. Inside a `List`, which is the sidebar and
/// Home, nothing the row starts itself reaches the screen: `.animation(_:value:)` on the label or
/// on the list, `.transaction(value:)`, and an `onChange` moving the row's own state inside
/// `withAnimation`, at once or a turn later, all reported no frames between. What does roll is a
/// write made inside `withAnimation`, including when the list draws a copy of it refreshed from an
/// `onChange`, which is the shape `SidebarView.regroup` has. The status glyph is the exception
/// the other way: its symbol replace plays in a list without any help.
///
///     BLOOM_DB_PATH=/tmp/probe.sqlite Bloom --numeric-text-probe
@MainActor
enum NumericTextProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--numeric-text-probe") }

    static func runAndExit() -> Never {
        guard Bundle.main.bundleIdentifier != "be.spatie.bloom" else { exit(1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
            for fixture in Fixture.allCases { print(await measure(fixture)) }
            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }

    @Observable
    final class Source {
        var value = 118
        var status: WorkspaceStatus { value == 118 ? .changed : .checksPassed }
    }

    enum Fixture: String, CaseIterable {
        case control, negative, diffStatPlain, countLabelPlain
        case diffStatList, controlList, mirroredList, deferredList, reenabledList, keyedList
        case glyphPlain, glyphList, glyphKeyedList, diffStatListExplicit, diffStatListRegrouped
    }

    /// The candidate for a list row: the number the row draws is the row's own state, moved in a
    /// transaction the row starts, rather than a value handed down through the list's reload.
    private struct MirroredFigure: View {
        var value: Int
        @State private var shown: Int?

        var body: some View {
            let figure = shown ?? value
            Text(figure, format: .number)
                .contentTransition(.numericText(value: Double(figure)))
                .onChange(of: value) { _, new in
                    withAnimation(Motion.hover) { shown = new }
                }
        }
    }

    /// The same row state, moved on the next turn of the run loop rather than inside the list's
    /// own update pass, in case that pass is what swallows the transaction.
    private struct DeferredFigure: View {
        var value: Int
        @State private var shown: Int?

        var body: some View {
            let figure = shown ?? value
            Text(figure, format: .number)
                .contentTransition(.numericText(value: Double(figure)))
                .onChange(of: value) { _, new in
                    Task { @MainActor in withAnimation(Motion.hover) { shown = new } }
                }
        }
    }

    /// The sidebar's own shape: the list draws a copy of the model held in the pane's state and
    /// refreshed from an `onChange`, rather than the model itself. The model is written inside
    /// `withAnimation` and the copy is not, so this answers whether the write's animation
    /// survives that hop.
    private struct RegroupedList: View {
        let source: Source
        @State private var rows: [Int] = []

        var body: some View {
            // One row with a fixed id, so a new figure is that row updated rather than a row
            // replaced. Keyed on the figure itself, the first version of this measured an
            // insertion and reported it as a jump.
            List([0], id: \.self) { _ in
                DiffStatLabel(additions: rows.first ?? 0, deletions: 4)
            }
            .onAppear { rows = [source.value] }
            .onChange(of: source.value) { _, new in rows = [new] }
        }
    }

    private struct FixtureView: View {
        let fixture: Fixture
        let source: Source

        var body: some View {
            switch fixture {
            case .control:
                Text(source.value, format: .number)
                    .contentTransition(.numericText(value: Double(source.value)))
            case .negative:
                Text(source.value, format: .number)
            case .diffStatPlain:
                DiffStatLabel(additions: source.value, deletions: 4)
            case .countLabelPlain:
                CountLabel(count: source.value)
            case .diffStatList:
                List { DiffStatLabel(additions: source.value, deletions: 4) }
            case .controlList:
                List {
                    Text(source.value, format: .number)
                        .contentTransition(.numericText(value: Double(source.value)))
                }
            case .mirroredList:
                List { MirroredFigure(value: source.value) }
            case .deferredList:
                List { DeferredFigure(value: source.value) }
            case .reenabledList:
                List {
                    Text(source.value, format: .number)
                        .contentTransition(.numericText(value: Double(source.value)))
                        .transaction(value: source.value) { transaction in
                            transaction.disablesAnimations = false
                            transaction.animation = Motion.hover
                        }
                }
            case .keyedList:
                List { DiffStatLabel(additions: source.value, deletions: 4) }
                    .animation(Motion.hover, value: source.value)
            case .diffStatListRegrouped:
                RegroupedList(source: source)
            case .diffStatListExplicit:
                List { DiffStatLabel(additions: source.value, deletions: 4) }
            case .glyphPlain:
                WorkspaceStatusGlyph(status: source.status)
            case .glyphList:
                List { WorkspaceStatusGlyph(status: source.status) }
            case .glyphKeyedList:
                List { WorkspaceStatusGlyph(status: source.status) }
                    .animation(Motion.pane, value: source.status)
            }
        }
    }

    private static func measure(_ fixture: Fixture) async -> String {
        let source = Source()
        let size = CGSize(width: 200, height: 60)
        let host = NSHostingView(rootView: FixtureView(fixture: fixture, source: source)
            .frame(width: size.width, height: size.height))
        host.wantsLayer = true
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        try? await Task.sleep(for: .milliseconds(300))
        let before = render(host)
        let start = ContinuousClock.now
        switch fixture {
        case .control, .controlList, .diffStatListExplicit, .diffStatListRegrouped:
            withAnimation(.easeOut(duration: 0.3)) { source.value = 942 }
        default:
            source.value = 942
        }
        var frames: [Data?] = []
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(8))
            frames.append(render(host))
        }
        let sampled = ContinuousClock.now - start
        try? await Task.sleep(for: .milliseconds(500))
        let after = render(host)
        let between = frames.filter { $0 != before && $0 != after }.count
        let settled = frames.firstIndex { $0 == after }.map(String.init) ?? "never"
        return "\(fixture.rawValue): changed=\(before != after) in-between=\(between)/\(frames.count) "
            + "first-final-frame=\(settled) sampled=\(sampled) visible=\(window.isVisible)"
    }

    private static func render(_ host: NSView) -> Data? {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let layer = host.layer else { return nil }
        if host.isFlipped {
            context.cgContext.translateBy(x: 0, y: host.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        context.flushGraphics()
        return bitmap.tiffRepresentation
    }
}
#endif
