import AppKit
import SwiftUI
import BloomCore

/// The starred metrics drawn into one template image for the status item.
///
/// **An image rather than an attributed title**, because two figures stacked into the height of the
/// menu bar is a layout, and a title is one line. Black on clear and marked as a template, so the
/// status bar tints it for a light bar, a dark bar and the pressed state the way it tints the mark.
@MainActor
enum MenuBarStripImage {
    private static var cache: (key: MenuBarUsageStrip, style: MenuBarIconStyle, image: NSImage)?

    static func image(for strip: MenuBarUsageStrip, style: MenuBarIconStyle) -> NSImage? {
        if let cache, cache.key == strip, cache.style == style { return cache.image }

        let content: AnyView
        if style == .bars, !strip.bars.isEmpty {
            content = AnyView(MenuBarBars(fractions: strip.bars))
        } else {
            content = AnyView(MenuBarTextStrip(groups: strip.groups))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = strip.spoken
        cache = (strip, style, image)
        return image
    }
}

/// Each provider's mark with its one or two figures beside it.
private struct MenuBarTextStrip: View {
    let groups: [MenuBarUsageStrip.Group]

    var body: some View {
        HStack(spacing: 11) {
            ForEach(groups) { group in
                HStack(spacing: 4) {
                    ProviderMarkView(provider: group.provider)
                        .frame(width: 16, height: 16)
                    if group.values.count == 1 {
                        Text(group.values[0])
                            .font(.system(size: 12, weight: .bold))
                    } else {
                        VStack(alignment: .trailing, spacing: -2) {
                            ForEach(Array(group.values.prefix(2).enumerated()), id: \.offset) { _, value in
                                Text(value)
                            }
                        }
                        .font(.system(size: 9, weight: .semibold))
                    }
                }
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

/// Up to four bars in an eighteen point square, OpenUsage's geometry.
private struct MenuBarBars: View {
    let fractions: [Double]
    private static let side: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            let count = max(1, min(MenuBarUsageStrip.maximumBars, fractions.count))
            let pad = max(1, (size.width * 0.08).rounded())
            let gap = max(1, (size.width * 0.03).rounded())
            let trackWidth = size.width - 2 * pad
            // A single bar is laid out as if there were two, so it does not fill the square.
            let slots = CGFloat(max(2, count))
            let trackHeight = max(1, ((size.height - 2 * pad - (slots - 1) * gap) / slots).rounded(.down))
            let total = CGFloat(count) * trackHeight + CGFloat(count - 1) * gap
            let top = pad + ((size.height - 2 * pad - total) / 2).rounded(.down)
            let radius = max(1, (trackHeight / 3).rounded(.down))

            for (index, fraction) in fractions.prefix(count).enumerated() {
                let y = top + CGFloat(index) * (trackHeight + gap)
                let track = CGRect(x: pad, y: y, width: trackWidth, height: trackHeight)
                context.fill(Path(roundedRect: track, cornerRadius: radius), with: .color(.black.opacity(0.24)))
                let filled = max(1, trackWidth * min(max(fraction, 0), 1))
                let fill = CGRect(x: pad, y: y, width: filled, height: trackHeight)
                context.fill(Path(roundedRect: fill, cornerRadius: radius), with: .color(.black))
            }
        }
        .frame(width: Self.side, height: Self.side)
    }
}
