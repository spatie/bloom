import SwiftUI
import Observation
import BatonCore

/// The terminal and browser tabs of every workspace, and which of them is showing.
///
/// A singleton for the same reason `TerminalSessionStore` is one: what a tab holds has to outlive
/// the view that draws it. Switching to another workspace and back must not reload a page or fork
/// a second shell, and a view cannot promise that about anything it owns itself.
///
/// It deliberately does not live on `AppModel`. Nothing outside the centre column has any business
/// knowing that a browser tab is open, and the tab list is the sort of state that is better lost
/// than migrated, which is why it is written to user defaults rather than to SQLite.
@MainActor
@Observable
final class CenterTabStore {
    static let shared = CenterTabStore()

    private(set) var tabsByWorkspace: [String: [CenterTab]] = [:]

    /// Which non-chat tab fills the column, per workspace. No entry means the conversation does,
    /// which is why selecting a chat tab only has to clear this rather than remember anything.
    private(set) var selectionByWorkspace: [String: String] = [:]

    /// Live web views, keyed by tab. Ignored by observation on purpose: no view reads this map, it
    /// is only ever asked for one session at a time, and having it invalidate the column every
    /// time a tab is first drawn would be a redraw for nothing.
    @ObservationIgnored private var browsers: [String: BrowserSession] = [:]

    private init() {}

    // MARK: - Reading

    func tabs(for workspaceID: String) -> [CenterTab] {
        tabsByWorkspace[workspaceID] ?? []
    }

    /// The tab filling the column, or nil when the conversation is.
    func selection(for workspaceID: String) -> CenterTab? {
        guard let id = selectionByWorkspace[workspaceID] else { return nil }
        return tabs(for: workspaceID).first { $0.id == id }
    }

    func isSelected(_ tab: CenterTab) -> Bool {
        selectionByWorkspace[tab.workspaceID] == tab.id
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
        selectionByWorkspace[workspaceID] = tab.id
        return tab
    }

    func select(_ tab: CenterTab?, in workspaceID: String) {
        selectionByWorkspace[workspaceID] = tab?.id
    }

    func rename(_ tab: CenterTab, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(tab) { $0.title = trimmed }
    }

    /// Called as the page navigates, so the tab remembers where it got to.
    func setURL(_ url: String, for tab: CenterTab) {
        guard !url.isEmpty, url != tab.url else { return }
        update(tab) { $0.url = url }
    }

    /// Closes a tab and stops whatever it was running. The column falls back to the conversation,
    /// which is the one thing in this workspace that cannot be closed away.
    func close(_ tab: CenterTab) async {
        apply(tabs(for: tab.workspaceID).filter { $0.id != tab.id }, to: tab.workspaceID)
        if selectionByWorkspace[tab.workspaceID] == tab.id {
            selectionByWorkspace[tab.workspaceID] = nil
        }

        switch tab.kind {
        case .browser:
            browsers[tab.id]?.stop()
            browsers[tab.id] = nil
        case .terminal:
            stopShell(for: tab)
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
        let base = kind == .terminal ? "Terminal" : "Browser"
        let taken = Set(tabs.filter { $0.kind == kind }.map(\.title))
        guard taken.contains(base) else { return base }
        var index = taken.count + 1
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
