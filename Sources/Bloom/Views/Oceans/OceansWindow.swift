import SwiftUI
import MapKit
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

    var body: some Scene {
        Window("Discovered Seas", id: Self.id) {
            OceansMapView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 560)
    }
}

/// The map itself, and the two counts under it.
///
/// The one rule of this window: it never shows the name of a sea that has not been used. Which
/// seas are left is meant to stay a small surprise, so the unused ones appear only as a count,
/// the same rule `OceanPick.notice` keeps.
private struct OceansMapView: View {
    @Environment(AppModel.self) private var app

    @State private var discovered: [Ocean] = []
    @State private var waitingCount = 0
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            if hasLoaded && discovered.isEmpty {
                ContentUnavailableView(
                    "No seas discovered yet",
                    systemImage: "map",
                    description: Text("Create a workspace and one will be named after the first.")
                )
            } else {
                Map {
                    ForEach(discovered) { ocean in
                        Annotation(ocean.name, coordinate: CLLocationCoordinate2D(
                            latitude: ocean.latitude, longitude: ocean.longitude
                        )) {
                            // A small dot rather than a `Marker` balloon: with dozens of seas
                            // discovered, full-size pins swallow the coastline the window is
                            // for. The ring keeps the dot visible on both sea and land tiles,
                            // and MapKit sets the label beside it.
                            Circle()
                                .fill(.tint)
                                .stroke(.background, lineWidth: 1.5)
                                .frame(width: 9, height: 9)
                        }
                    }
                }
            }

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
    private func load() async {
        guard let store = app.store else { return }
        let all = (try? await store.oceans()) ?? []
        discovered = all.filter { $0.usedAt != nil }
        waitingCount = (try? await store.unusedOceanCount()) ?? 0
        hasLoaded = true
    }
}
