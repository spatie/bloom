import SwiftUI
import Observation
import BloomCore

/// The terminal and browser tabs of every workspace, and which of them is showing.
///
/// A singleton for the same reason `TerminalSessionStore` is one: what a tab holds has to outlive
/// the view that draws it. Switching to another workspace and back must not reload a page or fork
/// a second shell, and a view cannot promise that about anything it owns itself.
///
/// It holds the list and the lifecycle, never which of them is on screen. Which tab the user is in,
/// and how that tab is carved into panes, is `WorkspaceTabsStore`'s business. Not every tab here is
/// an entry of the strip either: one absorbed into a pane of another tab is reached through that
/// tab, which is `TabSet.entries`.
///
/// It deliberately does not live on `AppModel`. Nothing outside the centre column has any business
/// knowing that a browser tab is open, and the tab list is the sort of state that is better lost
/// than migrated, which is why it is written to user defaults rather than to SQLite.
@MainActor
@Observable
final class CenterTabStore {
    static let shared = CenterTabStore()

    private(set) var tabsByWorkspace: [WorkspaceID: [CenterTab]] = [:]

    /// Workspaces whose stored list is there and would not decode.
    ///
    /// A decode failure and a workspace that has never opened a tool tab both leave an empty list
    /// in the map, and they are not the same fact. `WorkspaceTabsStore.reconcile` deletes every
    /// pane pointer no live tab answers for, so reading the first as the second would shred the
    /// arrangement of exactly the workspace whose record is already damaged. Ignored by
    /// observation because nothing draws from it: see `TerminalPaneCensus`, which keeps the same
    /// distinction for the orphan sweep, where getting it wrong costs a shell instead.
    @ObservationIgnored private var unreadable: Set<WorkspaceID> = []

    /// Live web views, keyed by tab. Ignored by observation on purpose: no view reads this map, it
    /// is only ever asked for one session at a time, and having it invalidate the column every
    /// time a tab is first drawn would be a redraw for nothing.
    @ObservationIgnored private var browsers: [String: BrowserSession] = [:]

    private init() {}

    // MARK: - Reading

    func tabs(for workspaceID: WorkspaceID) -> [CenterTab] {
        tabsByWorkspace[workspaceID] ?? []
    }

    /// Whether `tabs(for:)` is an answer rather than a placeholder: the list has been read back
    /// this launch, and it read cleanly. False is doubt, and the only caller that has to care is
    /// the one that deletes what it cannot account for.
    func hasReadTabs(for workspaceID: WorkspaceID) -> Bool {
        tabsByWorkspace[workspaceID] != nil && !unreadable.contains(workspaceID)
    }

    /// The workspace's one review tab, if it has been opened. There is never a second: see the
    /// note on `CenterTab`.
    func review(for workspaceID: WorkspaceID) -> CenterTab? {
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
    func load(workspaceID: WorkspaceID) {
        guard tabsByWorkspace[workspaceID] == nil else { return }
        guard let restored = Self.restore(workspaceID: workspaceID) else {
            // The strip has to draw something, and there is nothing to draw, so the map still gets
            // an empty list. What is remembered here is that it is not an answer.
            unreadable.insert(workspaceID)
            tabsByWorkspace[workspaceID] = []
            return
        }
        tabsByWorkspace[workspaceID] = restored
    }

    /// `title` is only passed by a caller that has a better name than "Terminal 3", which today
    /// means a run script opening a shell called after itself. Everything else takes the numbered
    /// name the strip has always given a new tab.
    @discardableResult
    func add(
        kind: CenterTab.Kind, workspaceID: WorkspaceID, url: String = "", title: String? = nil
    ) -> CenterTab {
        var tabs = tabs(for: workspaceID)
        let tab = CenterTab(
            workspaceID: workspaceID,
            kind: kind,
            title: title ?? Self.nextTitle(for: kind, in: tabs),
            url: url
        )
        tabs.append(tab)
        apply(tabs, to: workspaceID)
        return tab
    }

    /// Every terminal tab of a workspace, by id, without loading the workspace into the cache.
    ///
    /// The launch sweep asks this about workspaces nobody has opened, and it has to be told about
    /// their panes anyway: a tmux session whose tab is only on disk is still one Bloom can reach,
    /// and a sweep that could not see it would kill the shell the user left running in it.
    func terminalTabIDs(for workspaceID: WorkspaceID) -> [String] {
        let tabs = tabsByWorkspace[workspaceID] ?? Self.restore(workspaceID: workspaceID) ?? []
        return tabs.filter { $0.kind == .terminal }.map(\.id)
    }

    /// Takes over the terminal tabs the bottom panel used to keep in SQLite, once, and drops the
    /// rows behind it.
    ///
    /// A migrated tab keeps its id, and that is the whole point of doing it this way rather than
    /// opening fresh tabs: a pane id IS the tmux session name and the key `TerminalSplitStore`
    /// files a split layout under, so a shell the user left running in a split bottom panel tab
    /// comes back attached, in the same shape, in the centre column.
    ///
    /// **Not every row is worth a tab.** The panel opened a terminal for a workspace whether or
    /// not anybody wanted one: `load` created a tab called "Terminal" the first time a workspace
    /// was drawn, so there is a row for every workspace ever opened, and moving all of them across
    /// would put a spare shell in the strip of every workspace on the machine. What is carried
    /// over is what somebody did something to, which `isWorthKeeping` decides. The rest is dropped
    /// with its row.
    ///
    /// Nothing that is alive is dropped, and where that cannot be established the tab is kept. See
    /// `TerminalPersistence.sessions`.
    ///
    /// It costs nothing on any launch after the first: with no rows left there is nothing to ask
    /// tmux about, and the whole thing is one query that comes back empty.
    func adoptTerminalTabs(from store: Store?) async {
        guard let store, let workspaces = try? await store.workspaces() else { return }

        var rowsByWorkspace: [WorkspaceID: [TerminalTab]] = [:]
        for workspace in workspaces {
            let rows = (try? await store.terminalTabs(workspaceID: workspace.id)) ?? []
            if !rows.isEmpty { rowsByWorkspace[workspace.id] = rows }
        }
        guard !rowsByWorkspace.isEmpty else { return }

        // Asked once, for all of them, and only when there is something to decide. `nil` is tmux
        // failing to answer rather than answering with none, and it keeps every tab.
        let live = await TerminalSessionStore.shared.liveSessions(store: store).map(Set.init)

        for (workspaceID, rows) in rowsByWorkspace {
            var tabs = tabsByWorkspace[workspaceID] ?? Self.restore(workspaceID: workspaceID) ?? []
            let known = Set(tabs.map(\.id))

            for row in rows where !known.contains(row.id.rawValue) {
                guard Self.isWorthKeeping(row, in: workspaceID, live: live) else { continue }
                tabs.append(CenterTab(
                    id: row.id.rawValue, workspaceID: workspaceID, kind: .terminal, title: row.title
                ))
            }
            apply(tabs, to: workspaceID)

            for row in rows { try? await store.deleteTerminalTab(id: row.id) }
        }
    }

    /// Whether one of the bottom panel's terminal tabs is something rather than nothing.
    ///
    /// Three ways to be something, and any one of them is enough:
    ///
    /// - it was renamed, so somebody said what it was for;
    /// - it was split, so somebody arranged it;
    /// - a shell is still waiting for one of its panes on the tmux server.
    ///
    /// And one way to be kept without being any of them: `live` is nil when tmux could not be
    /// asked, and a tab that might be holding a running dev server is not something to throw away
    /// on a guess. A machine without tmux answers with none rather than with nil, because there
    /// nothing can be alive and that is a fact rather than a silence.
    private static func isWorthKeeping(
        _ row: TerminalTab, in workspaceID: WorkspaceID, live: Set<String>?
    ) -> Bool {
        if !isDefaultTitle(row.title) { return true }

        let panes = TerminalSplitStore.shared.panes(of: row.id.rawValue)
        if panes.count > 1 { return true }

        guard let live else { return true }
        return panes.contains {
            live.contains(TmuxSessions.sessionName(workspaceID: workspaceID, paneID: $0))
        }
    }

    /// Whether a title is one the panel handed out rather than one a person typed. It named the
    /// first tab of a workspace "Terminal" and the ones after it "Terminal 2", "Terminal 3", which
    /// is the same pair of shapes `nextTitle` still makes below.
    private static func isDefaultTitle(_ title: String) -> Bool {
        if title == "Terminal" { return true }
        guard title.hasPrefix("Terminal ") else { return false }
        return Int(title.dropFirst("Terminal ".count)) != nil
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
    func showReview(path: String, workspaceID: WorkspaceID) -> CenterTab {
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

    /// Closes a tab and stops whatever it was running. Any pane showing it goes with it, and the
    /// tab it was a pane of settles around the gap. See `TabSurgery`.
    func close(_ tab: CenterTab) async {
        apply(tabs(for: tab.workspaceID).filter { $0.id != tab.id }, to: tab.workspaceID)
        WorkspaceTabsStore.shared.forget(.tool(tab.id), workspaceID: tab.workspaceID)

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

    private func apply(_ tabs: [CenterTab], to workspaceID: WorkspaceID) {
        // Whatever could not be read is about to be overwritten by this, so the doubt goes with
        // it: from here the list in hand is the list on disk.
        unreadable.remove(workspaceID)
        tabsByWorkspace[workspaceID] = tabs
        Self.persist(tabs, workspaceID: workspaceID)
    }

    /// `TabDefaults` rather than a literal here, because `TerminalPaneCensus` reads the same key
    /// to decide which tmux sessions the orphan sweep may kill. The two used to state the prefix
    /// separately, with nothing pinning them together.
    private static func key(_ workspaceID: WorkspaceID) -> String { TabDefaults.tabListKey(workspaceID) }

    private static func persist(_ tabs: [CenterTab], workspaceID: WorkspaceID) {
        let defaults = UserDefaults.standard
        guard !tabs.isEmpty else {
            defaults.removeObject(forKey: key(workspaceID))
            return
        }
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: key(workspaceID))
    }

    /// Nil when a list is stored and will not decode, which is doubt. No key at all is a fact and
    /// answers with none: most workspaces have never opened a terminal or a browser.
    private static func restore(workspaceID: WorkspaceID) -> [CenterTab]? {
        guard let data = UserDefaults.standard.data(forKey: key(workspaceID)) else { return [] }
        return try? JSONDecoder().decode([CenterTab].self, from: data)
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
