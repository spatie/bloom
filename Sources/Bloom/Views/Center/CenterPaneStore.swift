import SwiftUI
import Observation
import BloomCore

/// How each workspace's centre column is carved into panes, and what each pane is showing.
///
/// A singleton for the same reason `CenterTabStore` and `TerminalSplitStore` are: the arrangement
/// has to outlive the view drawing it, so switching workspace and back cannot lose a split or
/// reload a page.
///
/// It holds the shape and the pointers, never the content. A pane names a session id or a tab id,
/// and the transcript, the shell and the web view all still hang off the stores that own them, so
/// closing a pane can never take a running agent with it by accident.
///
/// The unsplit case is deliberately the default and costs nothing: one pane, no stored layout, no
/// stored content, and the workspace's active session resolved on the fly. A workspace nobody has
/// split behaves exactly as it did before panes existed.
@MainActor
@Observable
final class CenterPaneStore {
    static let shared = CenterPaneStore()

    private var layouts: [WorkspaceID: SplitLayout] = [:]
    /// Keyed by pane id rather than nested under the workspace, because a pane id is unique and a
    /// pane is looked up far more often than a workspace's whole set is.
    private var contents: [String: CenterPaneContent] = [:]

    /// Bumped per workspace when focus moves by anything but a click, so the pane that now has it
    /// can go and take the keyboard. A counter, because moving away and straight back has to
    /// register twice.
    private var focusRequests: [WorkspaceID: Int] = [:]

    private static let keyPrefix = "center.panes."

    /// Read in one pass at launch rather than lazily per workspace. A getter may not mutate, and
    /// loading from a task would leave the first frame showing a single pane, which is long enough
    /// to fork a shell for a pane the restored layout does not have.
    private init() {
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix(Self.keyPrefix) {
            guard let data = value as? Data,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  let layout = SplitLayout(encoded: stored.layout) else { continue }
            layouts[WorkspaceID(String(key.dropFirst(Self.keyPrefix.count)))] = layout
            contents.merge(stored.contents) { _, new in new }
        }
    }

    // MARK: - Reading

    /// A workspace nobody has split is one pane carrying the workspace's own id.
    func layout(for workspaceID: WorkspaceID) -> SplitLayout {
        layouts[workspaceID] ?? SplitLayout(pane: workspaceID.rawValue)
    }

    func focusRequest(for workspaceID: WorkspaceID) -> Int {
        focusRequests[workspaceID] ?? 0
    }

    func focusedPane(in workspaceID: WorkspaceID) -> String {
        layout(for: workspaceID).focus
    }

    /// What a pane is showing, after checking that the thing it points at still exists.
    ///
    /// Resolved rather than trusted because both sides can vanish underneath a pane: a session is
    /// archived, a terminal tab is closed. A pane pointing at nothing shows the workspace's active
    /// conversation, which is the one thing a workspace cannot be without.
    func content(of pane: String, in model: WorkspaceModel) -> CenterPaneContent? {
        if let stored = contents[pane], isAlive(stored, in: model) { return stored }
        return model.activeSession.map { .chat($0.id) }
    }

    /// Whether a tab is showing in any pane, which is what the strip marks rather than a single
    /// selection: with the column split, two tabs are open at once and both are open.
    func isShowing(_ content: CenterPaneContent, in model: WorkspaceModel) -> Bool {
        layout(for: model.workspace.id).panes.contains { self.content(of: $0, in: model) == content }
    }

    private func isAlive(_ content: CenterPaneContent, in model: WorkspaceModel) -> Bool {
        switch content {
        case .chat(let id): model.sessions.contains { $0.id == id }
        case .tool(let id): CenterTabStore.shared.tabs(for: model.workspace.id).contains { $0.id == id }
        }
    }

    // MARK: - Writing

    /// Shows something in a pane. The pane takes focus, because the user just said this is what
    /// they want to be looking at.
    func show(_ content: CenterPaneContent, in pane: String, of workspaceID: WorkspaceID) {
        contents[pane] = content
        var layout = layout(for: workspaceID)
        if layout.focus != pane, layout.setFocus(pane) {
            apply(layout, to: workspaceID, movingFocus: false)
        } else {
            persist(workspaceID)
        }
    }

    /// Shows something in whichever pane the user is in, which is what clicking a tab means.
    func show(_ content: CenterPaneContent, in model: WorkspaceModel) {
        show(content, in: focusedPane(in: model.workspace.id), of: model.workspace.id)
    }

    /// Splits the focused pane and shows `content` in the half that opens. Returns the new pane.
    ///
    /// The new half takes what it was given rather than inheriting the old pane's content, because
    /// every route into this comes from the user naming a tab: a drag onto an edge, a menu item, or
    /// a keystroke that then asks which tab.
    @discardableResult
    func split(
        _ workspaceID: WorkspaceID,
        pane: String? = nil,
        axis: SplitAxis,
        showing content: CenterPaneContent?
    ) -> String? {
        var layout = layout(for: workspaceID)
        let target = pane ?? layout.focus
        let opened = newID()
        guard layout.split(target, axis: axis, into: opened) else { return nil }
        if let content { contents[opened] = content }
        _ = layout.setFocus(opened)
        apply(layout, to: workspaceID, movingFocus: true)
        return opened
    }

    /// Closes one pane. False means it was the only one, which is a column that cannot be closed:
    /// the tab strip's own close button is how a workspace loses its last conversation.
    @discardableResult
    func close(pane: String, in workspaceID: WorkspaceID) -> Bool {
        var layout = layout(for: workspaceID)
        guard layout.close(pane) else { return false }
        contents[pane] = nil
        apply(layout, to: workspaceID, movingFocus: true)
        return true
    }

    /// A pane the user clicked into. No focus request: it already has the keyboard, and asking for
    /// it again mid-click is how a click lands twice.
    func focus(_ pane: String, in workspaceID: WorkspaceID) {
        var layout = layout(for: workspaceID)
        guard layout.focus != pane, layout.setFocus(pane) else { return }
        apply(layout, to: workspaceID, movingFocus: false)
    }

    /// False when there is no pane that way, which lets the same keystroke fall through to the app
    /// menu rather than being swallowed by an edge.
    @discardableResult
    func moveFocus(_ direction: SplitDirection, in workspaceID: WorkspaceID) -> Bool {
        var layout = layout(for: workspaceID)
        guard layout.moveFocus(direction) else { return false }
        apply(layout, to: workspaceID, movingFocus: true)
        return true
    }

    func setRatio(_ ratio: Double, at path: [Int], in workspaceID: WorkspaceID) {
        var layout = layout(for: workspaceID)
        guard layout.setRatio(ratio, at: path) else { return }
        apply(layout, to: workspaceID, movingFocus: false)
    }

    /// Called when a tab goes away, so a pane that was showing it does not sit on a dead pointer
    /// until something else happens to reload the workspace.
    func forget(_ content: CenterPaneContent, in workspaceID: WorkspaceID) {
        let showing = layout(for: workspaceID).panes.filter { contents[$0] == content }
        guard !showing.isEmpty else { return }
        // The last pane keeps its place and falls back to the active conversation, because closing
        // a tab should never close the column it happened to be showing in.
        for pane in showing where layout(for: workspaceID).paneCount > 1 {
            _ = close(pane: pane, in: workspaceID)
        }
        for pane in showing { contents[pane] = nil }
        persist(workspaceID)
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var layout: String
        var contents: [String: CenterPaneContent]
    }

    private func apply(_ layout: SplitLayout, to workspaceID: WorkspaceID, movingFocus: Bool) {
        layouts[workspaceID] = layout
        if movingFocus { focusRequests[workspaceID] = focusRequest(for: workspaceID) + 1 }
        persist(workspaceID)
    }

    private func persist(_ workspaceID: WorkspaceID) {
        let defaults = UserDefaults.standard
        let key = Self.keyPrefix + workspaceID.rawValue
        let layout = layout(for: workspaceID)

        // An unsplit column is the default, so it is stored as nothing at all rather than as a
        // record saying so.
        guard layout.paneCount > 1, let encoded = layout.encoded else {
            defaults.removeObject(forKey: key)
            return
        }
        let mine = layout.panes.reduce(into: [String: CenterPaneContent]()) { result, pane in
            result[pane] = contents[pane]
        }
        guard let data = try? JSONEncoder().encode(Stored(layout: encoded, contents: mine)) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
