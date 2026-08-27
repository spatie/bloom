import SwiftUI
import BloomCore

/// The whole status column in one picture, at the size it is read at and enlarged enough to see
/// what each mark actually fills.
///
/// It exists because of a report that could not be answered any other way: "that arrow icon in the
/// list is very thin compared to the rest". The marks are decided one `case` at a time in
/// `WorkspaceStatusGlyph`, so nothing in the source shows the thing being complained about, which
/// is how a dozen of them look **beside each other** down 260 points. The legend is that picture in
/// the running app, and looking at the running app means putting a window in front of whoever is
/// using this Mac. This page is the same picture offscreen.
///
/// **It is now every state rather than thirteen of fifteen, and the two that were missing are the
/// reason the page was rewritten.** The second report was about size: "that green dot feels too
/// big ... they should fit same sizyness", made about three rows of one project whose marks were a
/// filled tick, the busy dot and a dotted ring. A page that leaves the busy dot off cannot be used
/// to answer it. So both absentees are drawn:
///
/// * `running` is drawn by the real `WorkspaceStatusGlyph`. Its figure is layer backed only while
///   the heartbeat is ticking, and no heartbeat ticks in an offscreen render, so what comes out is
///   the plain SwiftUI circle it rests as. That is the same figure `Reduce Motion` draws, and it is
///   the resting diameter that the size of this mark is judged on.
/// * `settingUp` is a `ProgressView`, which is an `NSProgressIndicator` behind a representable, and
///   `ImageRenderer` paints SwiftUI's yellow placeholder over any representable. It is drawn by
///   `SettingUpStill` instead, at the size AppKit gives the real one, and the page says so.
///
/// **The rows are laid out by `SidebarRowLabelStyle`, not by hand.** A page about how large the
/// marks are has to be drawn the way the pane draws them, or it photographs a size the window does
/// not use. That is not hypothetical here: the style used to raise the image scale, so this page
/// showed every symbol a quarter smaller than the sidebar did, and the mark that looked out of
/// family in the window looked fine on the page.
///
/// `--snapshot` writes it as `status-column-<appearance>.png`, and `--snapshot-gallery <dir>
/// --gallery status-column` draws it in a window if a real one is ever wanted.
struct StatusColumnGallery: View {
    /// Every state, in `WorkspaceStatus`'s own order, so the page cannot fall behind the enum: a
    /// state added there appears here without this file being touched.
    private static let states = WorkspaceStatus.allCases

    /// How far the marks are blown up in the lower half. Six, because the thing being looked at
    /// there is a fraction of a point of ink against a reference circle, and at four the two
    /// strokes touch.
    private static let magnification: CGFloat = 6

    /// The same states in fives, which is what the page is wide enough for. Split here rather than
    /// in the body: a `stride` in a `ViewBuilder` is a statement the builder has to be talked
    /// through, and this is the same list either way.
    private static var rows: [[WorkspaceStatus]] {
        stride(from: 0, to: states.count, by: 5).map {
            Array(states[$0..<min($0 + 5, states.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status column")
                    .font(Typo.title)
                Text("Every mark the column can draw, in the sidebar's own layout and at its own width.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                Text("Held still. \"Agent running\" is the real mark at rest, which is what Reduce Motion draws; \"Setting up\" is a stand-in for a spinner no offscreen render can photograph.")
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
            }

            HStack(alignment: .top, spacing: Metrics.gutter) {
                column("On the sidebar's own ground", onSelection: false, background: Palette.sidebar)
                column("On a selected row", onSelection: true, background: Palette.accentFill)
            }

            boxes
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
    }

    // MARK: The column, at the width it is read at

    private func column(_ title: String, onSelection: Bool, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            VStack(spacing: 0) {
                ForEach(Self.states, id: \.self) { row($0, onSelection: onSelection) }
            }
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// One row, at the sidebar's width, pitch and indent, with the mark in the column the pane puts
    /// it in rather than in an arrangement invented for this page.
    private func row(_ status: WorkspaceStatus, onSelection: Bool) -> some View {
        Label {
            Text(status.label)
                .foregroundStyle(onSelection ? Palette.textInverted : Palette.textPrimary)
        } icon: {
            mark(status, onSelection: onSelection)
        }
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
        .frame(width: Metrics.sidebarWidth, height: 32, alignment: .leading)
    }

    // MARK: The same marks against the box and the ink they are meant to fill

    /// Every mark blown up on two references: the 13 point box `Metrics.glyph` frames it in, and
    /// the 11.25 points of ink `Metrics.glyphInk` says a round symbol in that box draws.
    ///
    /// The references are the point of the section. A mark on its own tells you nothing about
    /// whether it is in family; a mark drawn over the circle its neighbours fill says at a glance
    /// that it overflows, sits on it, or is a bare disc deliberately inside it.
    private var boxes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Each mark on its box, at six times")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Text("Outer square: the \(Self.number(Metrics.glyph)) point box every mark is framed in. Inner circle: the \(Self.number(Metrics.glyphInk)) points of ink a round symbol in it draws.")
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)

            ForEach(Self.rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: Metrics.gutter) {
                    ForEach(Self.rows[index], id: \.self) { enlarged($0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func enlarged(_ status: WorkspaceStatus) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // A hairline once magnified, which is what these two references have to be: drawn
                // any heavier they read as part of the mark rather than as the rule it is being
                // held against.
                Rectangle()
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline / Self.magnification)
                Circle()
                    .strokeBorder(
                        Palette.accent.opacity(0.4),
                        style: StrokeStyle(
                            lineWidth: Metrics.hairline / Self.magnification,
                            dash: [1, 1]
                        )
                    )
                    .frame(width: Metrics.glyphInk, height: Metrics.glyphInk)
                mark(status, onSelection: false)
            }
            .frame(width: Metrics.glyph, height: Metrics.glyph)
            .scaleEffect(Self.magnification, anchor: .center)
            .frame(
                width: Metrics.glyph * Self.magnification,
                height: Metrics.glyph * Self.magnification
            )
            .background(Palette.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(status.label)
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.glyph * Self.magnification)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: The two the renderer cannot photograph

    @ViewBuilder
    private func mark(_ status: WorkspaceStatus, onSelection: Bool) -> some View {
        if status == .settingUp {
            SettingUpStill()
        } else {
            WorkspaceStatusGlyph(status: status, isOnSelection: onSelection)
        }
    }

    /// A number without its trailing zero, so the captions read "13" and "11.25" rather than
    /// "13.0". Built here because the page prints the metrics it is drawing against, and a caption
    /// claiming a number the constant no longer holds is worse than no caption.
    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
    }
}

/// The spinner at the head of a workspace that is being set up, held still.
///
/// `WorkspaceStatusGlyph` answers that state with a circular `ProgressView`, which is an
/// `NSProgressIndicator` behind a representable, and `ImageRenderer` paints SwiftUI's yellow
/// placeholder over a representable. So the one state the column draws with a system control was
/// the one state a size audit could not see, and the page simply left it off.
///
/// The figure is the spinner's own: `.controlSize(.mini)` is a 10 by 10 indicator, measured off
/// `NSProgressIndicator.intrinsicContentSize` for each control size (32, 16, 10), and it rests as
/// eight spokes on a ring. It is a stand-in and the page says as much, but it is a stand-in at the
/// right size, which is the only claim this page makes about it.
private struct SettingUpStill: View {
    private static let indicator: CGFloat = 10
    private static let spokes = 8

    var body: some View {
        ZStack {
            ForEach(0..<Self.spokes, id: \.self) { spoke in
                Capsule()
                    .fill(Palette.textTertiary)
                    .frame(width: Self.indicator / 8, height: Self.indicator / 3)
                    .offset(y: -(Self.indicator - Self.indicator / 3) / 2)
                    .rotationEffect(.degrees(Double(spoke) / Double(Self.spokes) * 360))
            }
        }
        .frame(width: Metrics.glyph, height: Metrics.glyph)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Nothing on it moves and nothing on it is typed into, so it asks for neither the heartbeat
    /// nor the keys. Taller than it was: the page carries all fifteen states now rather than
    /// thirteen, and carries them twice.
    static let statusColumn = Gallery(
        name: "status-column",
        title: "Status column",
        size: CGSize(width: 640, height: 1080),
        needsFocus: false,
        view: { _ in AnyView(StatusColumnGallery()) }
    )
}
