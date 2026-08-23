import SwiftUI
import AppKit
import BloomCore

/// The map of the seas workspaces have been named after.
///
/// A window rather than a pane, because it is a curiosity to leave open beside the main window,
/// not a step in any flow. A plain `Window` rather than a `WindowGroup`: there is one catalogue,
/// so a second copy of this map could only ever disagree with the first.
struct OceansWindow: Scene {
    let model: AppModel

    /// The scene id. Opening this window from anywhere is `openWindow(id:)` with it.
    static let id = "oceans"

    /// **There is no menu item for this window in `BloomCommands`, and there must not be.**
    ///
    /// A `Window` scene puts its own item in the Window menu, named after the window, and that
    /// item is not the list of open windows: it opens the window when it is closed and brings it
    /// to the front when it is not. Measured, because the difference is the whole question. So a
    /// command of our own whose only job was to open this window printed "Discovered Seas" twice
    /// in the same menu, once as SwiftUI's item and once under a separator as ours, with nothing
    /// to tell a reader which was which.
    ///
    /// The command was the copy, so the command went. Renaming ours to "Show Discovered Seas"
    /// was the tempting version and merely made the duplicate legible; hiding ours while the
    /// window was open would have made the menu change shape under somebody learning it. Neither
    /// buys anything the free item does not already do. It buys one thing less: a shortcut, which
    /// this window never had and does not want.
    ///
    /// If this window ever needs a key equivalent, that is the moment to put a command back, and
    /// it will have to be named so it cannot be read as the line above it.

    var body: some Scene {
        Window("Discovered Seas", id: Self.id) {
            OceansMapView()
                .environment(model)
        }
        .defaultSize(width: Self.openingSize.width, height: Self.openingSize.height)
    }

    /// The size the window opens at the first time, and only then.
    ///
    /// It used to be a flat 760 by 560, which on anything larger than a laptop panel opened a
    /// postage stamp of a chart with names too small to read. Four fifths of the screen is the
    /// size a chart wants; `defaultWindowSize` turns that budget into a window cut exactly to
    /// the two by one sheet, so a very wide or very tall display does not open with a band of
    /// blank paper that no content will ever reach.
    ///
    /// **A frame the user has set wins.** `.defaultSize` is only consulted when the scene has no
    /// restored frame of its own, and a `Window` scene saves its frame the moment it is moved or
    /// resized, so this value is a starting position rather than a rule reapplied on every open.
    /// Nothing here reaches for the window afterwards to enforce it, which was the tempting
    /// version and would have thrown away a size the user had chosen every time the window was
    /// reopened.
    ///
    /// The screen is `NSScreen.main` read once as the scene is built, because a default size has
    /// to exist before there is a window to ask which display it landed on. On a two screen desk
    /// that is the screen the app was frontmost on, which is where the window will open.
    static let openingSize: (width: Double, height: Double) = {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return SeaChartProjection.defaultWindowSize(
            screenWidth: screen.width, screenHeight: screen.height,
            margin: SeaChartView.margin, footerHeight: 38
        )
    }()
}

/// The chart and the two counts under it.
///
/// The one rule of this window: it never shows the name of a sea that has not been used. Which
/// seas are left is meant to stay a small surprise, so the unused ones appear only as a count,
/// the same rule `OceanPick.notice` keeps.
///
/// The chart is always the whole world, marks or none: `SeaChartView` draws the sheet itself,
/// so there is no camera to fit and no empty placeholder standing in for the map. The empty
/// state is written onto the water instead of replacing it, because a chart of unnamed seas is
/// the invitation.
private struct OceansMapView: View {
    @Environment(AppModel.self) private var app

    @State private var discovered: [Ocean] = []
    @State private var waitingCount = 0
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            SeaChartView(
                discovered: discovered,
                showEmptyNotice: hasLoaded && discovered.isEmpty
            )
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Palette.windowBackground)
        // `.task` rather than `.onAppear`, so a claim made while this window sits open is picked
        // up the next time the window is opened: closing a `Window` scene tears this view down,
        // and reopening it runs the task again.
        .task { await load() }
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            // The gestures written down, because a chart shows no controls on purpose and a
            // gesture nobody is told about is a gesture nobody uses.
            Text("Pinch to zoom, scroll to pan, double click for the whole world")
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingWide)
        .background(Palette.sidebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: Metrics.hairline)
        }
    }

    /// The two facts, worded so both counts read in one glance. Counts only for the waiting
    /// seas: naming them here would give away exactly what the claim keeps as a surprise.
    private var summary: String {
        let found = discovered.count
        let foundPart = found == 1 ? "1 sea discovered." : "\(found) seas discovered."
        let waitingPart: String
        switch waitingCount {
        case 0: waitingPart = "None are left waiting."
        case 1: waitingPart = "1 is still waiting."
        default: waitingPart = "\(waitingCount) are still waiting."
        }
        return "\(foundPart) \(waitingPart)"
    }

    /// Reads the catalogue from the store. Reading is all this window ever does: seas are spent
    /// by `startWorkspace`, never from here.
    ///
    /// Sorted by discovery date because label placement is greedy in order: the first sea
    /// found in a crowded corner keeps its name when later neighbours arrive, rather than the
    /// names reshuffling under the user every time the catalogue grows.
    private func load() async {
        guard let store = app.store else { return }
        let all = (try? await store.oceans()) ?? []
        discovered = all
            .filter { $0.usedAt != nil }
            .sorted { ($0.usedAt ?? .distantPast, $0.slug) < ($1.usedAt ?? .distantPast, $1.slug) }
        waitingCount = (try? await store.unusedOceanCount()) ?? 0
        hasLoaded = true
    }
}
