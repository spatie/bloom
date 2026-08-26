import SwiftUI
import Observation
import BloomCore

/// How every terminal tab is carved into panes.
///
/// A singleton for the same reason `TerminalSessionStore` is one: the arrangement has to outlive
/// the view drawing it, and it is shared by the centre column and the bottom panel, which are two
/// view trees with no ancestor between them.
///
/// It holds only the shape. The shells hang off `TerminalSessionStore` by pane id, so splitting,
/// zooming and closing here can never take a running process with them by accident.
@MainActor
@Observable
final class TerminalSplitStore {
    static let shared = TerminalSplitStore()

    /// Keyed by the id of the tab the panes belong to, which is also the id of its first pane.
    private var layouts: [String: SplitLayout] = [:]

    /// Bumped per tab when the keyboard is moved by anything other than a click, so the pane that
    /// now has focus can go and take it. A counter rather than a flag because moving focus away
    /// and straight back has to register twice.
    private var focusRequests: [String: Int] = [:]

    /// `TabDefaults` rather than a literal here, because `TerminalPaneCensus` walks the same keys
    /// to decide which tmux sessions the orphan sweep may kill. A prefix that drifted on one side
    /// only would have the sweep see none of the panes below and kill the shells behind them.
    private static let keyPrefix = TabDefaults.splitPrefix

    /// Read in one pass at launch rather than lazily per tab. A getter may not mutate, and loading
    /// from a task instead would leave the first frame showing a single pane, which is long enough
    /// to fork a shell for a pane the restored layout does not have.
    ///
    /// The app's own domain rather than `dictionaryRepresentation()`, which merges the whole
    /// search list in to answer about one prefix. See `DefaultsSnapshot`. Its own snapshot rather
    /// than one shared with `WorkspaceTabsStore`, because these two are reached from different
    /// call sites in `bootstrap` and a snapshot handed across them would be a cache with a
    /// lifetime nobody owns, for a domain of 87 entries.
    private init() {
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot.own(defaults, name: Bundle.main.bundleIdentifier)
        for (key, value) in snapshot where key.hasPrefix(Self.keyPrefix) {
            guard let encoded = value as? String, let layout = SplitLayout(encoded: encoded) else {
                continue
            }
            layouts[String(key.dropFirst(Self.keyPrefix.count))] = layout
        }
    }

    // MARK: - Reading

    /// A tab nobody has split is one pane carrying the tab's own id, which is what keeps a shell
    /// that was forked before this type existed exactly where it was.
    func layout(for ownerID: String) -> SplitLayout {
        layouts[ownerID] ?? SplitLayout(pane: ownerID)
    }

    func focusRequest(for ownerID: String) -> Int {
        focusRequests[ownerID] ?? 0
    }

    /// Every pane of a tab, for a caller that has to stop what is running in them.
    func panes(of ownerID: String) -> [String] {
        layout(for: ownerID).panes
    }

    // MARK: - Writing

    /// Splits the focused pane and returns the new one, so the caller can fork its shell.
    @discardableResult
    func split(_ ownerID: String, axis: SplitAxis) -> String? {
        var layout = layout(for: ownerID)
        let pane = newID()
        guard layout.split(layout.focus, axis: axis, into: pane) else { return nil }
        apply(layout, to: ownerID, movingFocus: true)
        return pane
    }

    /// Returns false when that was the last pane, which is the tab's cue to close itself.
    ///
    /// The keyboard is only asked for when the pane that went was holding it. Cmd+W always closes
    /// the pane the keystroke came from, so this reads as it always did there, but a shell that
    /// ends by itself can close a pane the user is not in, and grabbing the keyboard off the back
    /// of that would pull the caret out of whatever they were typing in.
    func close(pane: String, in ownerID: String) -> Bool {
        var layout = layout(for: ownerID)
        let hadFocus = layout.focus == pane
        guard layout.close(pane) else { return false }
        apply(layout, to: ownerID, movingFocus: hadFocus)
        return true
    }

    /// A pane the user clicked into. No focus request: the pane already has the keyboard, and
    /// asking for it again mid-click is how a click ends up landing twice.
    func focus(_ pane: String, in ownerID: String) {
        var layout = layout(for: ownerID)
        guard layout.focus != pane, layout.setFocus(pane) else { return }
        apply(layout, to: ownerID, movingFocus: false)
    }

    /// False when there is no pane that way, which lets the same keystroke fall through to the
    /// app menu, where Cmd+Option+Up and Cmd+Option+Down step through workspaces.
    func moveFocus(_ direction: SplitDirection, in ownerID: String) -> Bool {
        var layout = layout(for: ownerID)
        guard layout.moveFocus(direction) else { return false }
        apply(layout, to: ownerID, movingFocus: true)
        return true
    }

    func toggleZoom(in ownerID: String) -> Bool {
        var layout = layout(for: ownerID)
        guard layout.toggleZoom() else { return false }
        apply(layout, to: ownerID, movingFocus: true)
        return true
    }

    func setRatio(_ ratio: Double, at path: [Int], in ownerID: String) {
        var layout = layout(for: ownerID)
        guard layout.setRatio(ratio, at: path) else { return }
        apply(layout, to: ownerID, movingFocus: false)
    }

    /// Called when the tab itself goes away, so a new tab reusing nothing starts unsplit and user
    /// defaults do not fill up with the shapes of tabs that are gone.
    func discard(ownerID: String) {
        layouts[ownerID] = nil
        focusRequests[ownerID] = nil
        UserDefaults.standard.removeObject(forKey: Self.keyPrefix + ownerID)
    }

    // MARK: - Persistence

    private func apply(_ layout: SplitLayout, to ownerID: String, movingFocus: Bool) {
        layouts[ownerID] = layout
        if movingFocus { focusRequests[ownerID] = focusRequest(for: ownerID) + 1 }
        persist(layout, for: ownerID)
    }

    private func persist(_ layout: SplitLayout, for ownerID: String) {
        let defaults = UserDefaults.standard
        let key = Self.keyPrefix + ownerID

        // An unsplit tab is the default, so it is stored as nothing at all rather than as a
        // record saying so.
        guard layout.paneCount > 1, let encoded = layout.encoded else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(encoded, forKey: key)
    }
}
