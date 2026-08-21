import Foundation
import Observation
import BloomCore

/// One name that has just arrived and should be revealed rather than swapped in.
struct WorkspaceNameReveal: Equatable, Identifiable {
    let id = UUID()
    /// The name the reveal resolves to. Checked by the view against the text it is drawing, so a
    /// reveal announced for one name can never play over a different one.
    let name: String
    /// Fixes the churn, so two views showing the same workspace scramble identically.
    let seed: UInt64
}

/// Which workspaces are mid reveal, right now.
///
/// A register rather than a flag on the workspace, because the reveal is a fact about this instant
/// in this app and not about the row in the database. Restarting Bloom must not replay it, and
/// nothing about it is worth persisting.
///
/// It exists at all because more than one view can be drawing the same workspace's name when it
/// lands, and they have to agree. A per-view flag would have the sidebar and Home churning out of
/// step; a consumed one-shot would have whichever view drew first steal the reveal from the other.
@MainActor
@Observable
final class WorkspaceNameReveals {
    static let shared = WorkspaceNameReveals()

    private(set) var reveals: [WorkspaceID: WorkspaceNameReveal] = [:]

    /// How long an announcement stays on the register.
    ///
    /// The reveal's own length plus a beat. Past that it is cleared, so a sidebar row scrolled
    /// into view a minute later draws the name straight instead of replaying an animation for an
    /// event that is over.
    private static let lifetime = ScrambleReveal.interval * (ScrambleReveal.steps + 4)

    private var expiries: [WorkspaceID: Task<Void, Never>] = [:]

    /// Announce that Bloom, not the user, just renamed this workspace.
    ///
    /// The only caller is the automatic naming path. A rename typed into the sidebar's own text
    /// field never comes through here, which is what stops a user's typing being garbled back at
    /// them.
    func announce(workspaceID: WorkspaceID, name: String) {
        reveals[workspaceID] = WorkspaceNameReveal(name: name, seed: UInt64.random(in: .min ... .max))

        expiries[workspaceID]?.cancel()
        expiries[workspaceID] = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.reveals[workspaceID] = nil
            self?.expiries[workspaceID] = nil
        }
    }

    /// The reveal for this workspace, but only if it is for the text about to be drawn.
    func reveal(for workspaceID: WorkspaceID, showing name: String) -> WorkspaceNameReveal? {
        guard let reveal = reveals[workspaceID], reveal.name == name else { return nil }
        return reveal
    }
}
