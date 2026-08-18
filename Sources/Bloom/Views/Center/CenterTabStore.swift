import SwiftUI
import Observation
import BloomCore

/// The terminal and browser tabs of every workspace, and which of them is showing.
///
/// A singleton for the same reason `TerminalSessionStore` is one: what a tab holds has to outlive
/// the view that draws it. Switching to another workspace and back must not reload a page or fork
/// a second shell, and a view cannot promise that about anything it owns itself.
///
/// It holds the list and the lifecycle, never which of them is on screen. Where a tab is showing is
/// `CenterPaneStore`'s business, because with the column split the answer is a pane rather than a
/// workspace, and two tabs can be showing at once.
///
/// It deliberately does not live on `AppModel`. Nothing outside the centre column has any business
/// knowing that a browser tab is open, and the tab list is the sort of state that is better lost
/// than migrated, which is why it is written to user defaults rather than to SQLite.
@MainActor
@Observable
final class CenterTabStore {
    static let shared = CenterTabStore()

    private(set) var tabsByWorkspace: [String: [CenterTab]] = [:]

    /// Live web views, keyed by tab. Ignored by observation on purpose: no view reads this map, it
    /// is only ever asked for one session at a time, and having it invalidate the column every
    /// time a tab is first drawn would be a redraw for nothing.
    @ObservationIgnored private var browsers: [String: BrowserSession] = [:]

    private init() {}

    // MARK: - Reading

    func tabs(for workspaceID: String) -> [CenterTab] {
        tabsByWorkspace[workspaceID] ?? []
    }

    /// The workspace's one review tab, if it has been opened. There is never a second: see the
    /// note on `CenterTab`.
    func review(for workspaceID: String) -> CenterTab? {
        tabs(for: workspaceID).first { $0.kind == .review }
    }

    /// What the strip calls a tab. Only a review tab needs asking: it is named after what it is
    /// showing rather than after itself, so that a file nobody changed is not filed under "All
    /// changes", and the answer moves as the reader walks the list.
    func displayTitle(of tab: CenterTab, in model: WorkspaceModel) -> String {
        guard tab.kind == .review, !tab.path.isEmpty else { return tab.title }
        if model.changedFiles.contains(where: { $0.path == tab.path }) { return tab.title }
        return (tab.path as NSString).lastPathComponent
    }

    // MARK: - Writing

    /// Reads the workspace's tabs back from user defaults, once per launch. Called from a task
    /// rather than from a getter, because filling the map is a mutation and a view body may not
    /// cause one.
    func load(workspaceID: String) {
        guard tabsByWorkspace[workspaceID] == nil else { return }
        tabsByWorkspace[workspaceID] = Self.restore(workspaceID: workspaceID)
    }

    @discardableResult
    func add(kind: CenterTab.Kind, workspaceID: String, url: String = "") -> CenterTab {
        var tabs = tabs(for: workspaceID)
        let tab = CenterTab(
            workspaceID: workspaceID,
            kind: kind,
            title: Self.nextTitle(for: kind, in: tabs),
            url: url
        )
        tabs.append(tab)
        apply(tabs, to: workspaceID)
        return tab
    }

    /// Moves a tool tab to another place in the strip. Tool tabs keep their own run of the strip
    /// after the conversations, so an index here is an index among tool tabs only.
    func move(_ tab: CenterTab, to index: Int) {
        var ordered = tabs(for: tab.workspaceID)
        guard let from = ordered.firstIndex(where: { $0.id == tab.id }) else { return }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: min(max(index, 0), ordered.count))
        apply(ordered, to: tab.workspaceID)
    }

    func rename(_ tab: CenterTab, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(tab) { $0.title = trimmed }
    }

    /// Opens the workspace's review tab on a file, or points the one it already has at it.
    ///
    /// Returns the tab either way, so the caller can decide where to show it. It does not decide
    /// that itself: a review already open in one half of a split column must not be dragged into
    /// the half the reader is typing in just because they clicked a filename.
    @discardableResult
    func showReview(path: String, workspaceID: String) -> CenterTab {
        if let existing = review(for: workspaceID) {
            if existing.path != path { update(existing) { $0.path = path } }
            return review(for: workspaceID) ?? existing
        }
        var tabs = tabs(for: workspaceID)
        let tab = CenterTab(
            workspaceID: workspaceID,
            kind: .review,
            title: CenterTab.reviewTitle,
            path: path
        )
        tabs.append(tab)
        apply(tabs, to: workspaceID)
        return tab
    }

    /// Called as the page navigates, so the tab remembers where it got to.
    func setURL(_ url: String, for tab: CenterTab) {
        guard !url.isEmpty, url != tab.url else { return }
        update(tab) { $0.url = url }
    }

    /// Closes a tab and stops whatever it was running. Any pane showing it falls back to the
    /// conversation, which is the one thing in this workspace that cannot be closed away.
    func close(_ tab: CenterTab) async {
        apply(tabs(for: tab.workspaceID).filter { $0.id != tab.id }, to: tab.workspaceID)
        CenterPaneStore.shared.forget(.tool(tab.id), in: tab.workspaceID)

        switch tab.kind {
        case .browser:
            browsers[tab.id]?.stop()
            browsers[tab.id] = nil
        case .terminal:
            stopShell(for: tab)
        // A review holds nothing: the diff is re-read from git whenever it is drawn, and any
        // unsaved edit belongs to `FileEditSession`, which outlives every view that shows it.
        case .review:
            break
        }
    }

    // MARK: - Sessions

    /// The live web view for a browser tab, created on first use and reused forever after.
    func browser(for tab: CenterTab) -> BrowserSession {
        if let existing = browsers[tab.id] { return existing }
        let session = BrowserSession(url: tab.url)
        browsers[tab.id] = session
        return session
    }

    /// A centre tab is not one of the bottom panel's rows: it has no `terminal_tabs` record and no
    /// place in that panel's list, so there is nothing to delete and only shells to stop. Every
    /// pane goes, which for a tab the user never split is the one shell it opened with.
    ///
    /// It deliberately does not go through `closeTab`. That one opens a replacement tab when it
    /// empties a workspace's list, so a centre tab could conjure a bottom panel terminal for a
    /// workspace whose panel had not loaded yet.
    private func stopShell(for tab: CenterTab) {
        TerminalSessionStore.shared.closePanes(of: tab.id)
    }

    // MARK: - Persistence

    private func update(_ tab: CenterTab, _ change: (inout CenterTab) -> Void) {
        var tabs = tabs(for: tab.workspaceID)
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        change(&tabs[index])
        apply(tabs, to: tab.workspaceID)
    }

    private func apply(_ tabs: [CenterTab], to workspaceID: String) {
        tabsByWorkspace[workspaceID] = tabs
        Self.persist(tabs, workspaceID: workspaceID)
    }

    private static func key(_ workspaceID: String) -> String { "center.tabs.\(workspaceID)" }

    private static func persist(_ tabs: [CenterTab], workspaceID: String) {
        let defaults = UserDefaults.standard
        guard !tabs.isEmpty else {
            defaults.removeObject(forKey: key(workspaceID))
            return
        }
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: key(workspaceID))
    }

    private static func restore(workspaceID: String) -> [CenterTab] {
        guard let data = UserDefaults.standard.data(forKey: key(workspaceID)),
              let tabs = try? JSONDecoder().decode([CenterTab].self, from: data) else { return [] }
        return tabs
    }

    /// "Terminal", then "Terminal 2". The bare first name matches what the bottom panel calls its
    /// own first shell, and numbering from the count skips a name only when one is already taken.
    private static func nextTitle(for kind: CenterTab.Kind, in tabs: [CenterTab]) -> String {
        let base = switch kind {
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .review: CenterTab.reviewTitle
        }
        let taken = Set(tabs.filter { $0.kind == kind }.map(\.title))
        guard taken.contains(base) else { return base }
        var index = taken.count + 1
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
