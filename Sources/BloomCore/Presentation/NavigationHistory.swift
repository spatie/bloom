import Foundation

/// Somewhere the window can be put back: a sidebar selection and, in a workspace, its tab.
///
/// A subagent or crew selection is the workspace narrowed for a moment, so it is filed as the
/// workspace. Archived items are read, not worked in, and are not places.
public struct NavigationPlace: Hashable, Sendable {
    public let selection: SidebarSelection
    public let tab: PaneContent?

    public init?(selection: SidebarSelection, tab: PaneContent?) {
        switch selection {
        case .home, .mail, .conversation:
            self.init(resolved: selection, tab: nil)
        case .workspace(let id), .subagent(let id, _), .subagentCall(let id, _), .crew(let id, _):
            self.init(resolved: .workspace(id), tab: tab)
        case .archived, .archivedConversation:
            return nil
        }
    }

    private init(resolved selection: SidebarSelection, tab: PaneContent?) {
        self.selection = selection
        self.tab = tab
    }

    /// The live lists own reachability, including project-free conversations that have closed.
    public func isReachable(
        workspace: (WorkspaceID, PaneContent?) -> Bool,
        conversation: (SessionID) -> Bool
    ) -> Bool {
        switch selection {
        case .home, .mail: true
        case .workspace(let id): workspace(id, tab)
        case .conversation(let id): conversation(id)
        case .archived, .archivedConversation, .subagent, .subagentCall, .crew: false
        }
    }
}

/// Back and Forward across workspaces and their tabs, the way a browser steps through pages.
///
/// A new place cuts off what lay ahead of the cursor, so Forward only answers after a Back.
/// Places that are gone (archived workspace, closed tab) are stepped over, not stopped at.
public struct NavigationHistory: Sendable {
    public private(set) var places: [NavigationPlace] = []
    public private(set) var index = -1

    public init() {}

    static let capacity = 100

    public mutating func visit(_ place: NavigationPlace) {
        guard places.indices.contains(index) else {
            places = [place]
            index = 0
            return
        }
        guard places[index] != place else { return }
        // An arriving tab completes its unresolved workspace entry. A narrowed sidebar selection
        // names that workspace without a tab and must not discard the tab or add another step.
        if places[index].selection == place.selection,
           places[index].tab == nil || place.tab == nil {
            if place.tab != nil { places[index] = place }
            return
        }
        places = Array(places.prefix(index + 1)) + [place]
        if places.count > Self.capacity { places.removeFirst() }
        index = places.count - 1
    }

    /// The first departure keeps Home available to Back. Later departures only complete an
    /// unresolved arrival, so an automatic fallback after closing a tab does not add a visit.
    public mutating func recordDeparture(_ place: NavigationPlace) {
        if places.isEmpty {
            visit(place)
        } else if let workspace = place.selection.workspaceID, let tab = place.tab {
            settle(tab, in: workspace)
        }
    }

    /// A workspace is filed on arrival, before its strip has loaded, so it has no tab. When the
    /// user leaves the tab it opened on, this names it, so Back can return there.
    public mutating func settle(_ tab: PaneContent, in workspace: WorkspaceID) {
        guard places.indices.contains(index), places[index].tab == nil,
              places[index].selection == .workspace(workspace),
              let settled = NavigationPlace(selection: .workspace(workspace), tab: tab)
        else { return }
        places[index] = settled
    }

    /// The reachable place `delta` steps away, with the cursor moved onto it. Nil, and the cursor
    /// untouched, when there is none.
    public mutating func move(
        _ delta: Int, isReachable: (NavigationPlace) -> Bool
    ) -> NavigationPlace? {
        guard let target = target(delta, isReachable: isReachable) else { return nil }
        index = target
        return places[target]
    }

    public func canMove(_ delta: Int, isReachable: (NavigationPlace) -> Bool) -> Bool {
        target(delta, isReachable: isReachable) != nil
    }

    private func target(_ delta: Int, isReachable: (NavigationPlace) -> Bool) -> Int? {
        let direction = delta < 0 ? -1 : 1
        var candidate = index + direction
        while places.indices.contains(candidate) {
            if isReachable(places[candidate]) { return candidate }
            candidate += direction
        }
        return nil
    }

    /// Control+Tab forwards, Shift+Control+Tab back. Exact, so Option+Control+Tab and
    /// Command+Control+Tab stay the system's.
    public static func step(forTabWith modifiers: MenuShortcut.Modifiers) -> Int? {
        switch modifiers {
        case [.control]: 1
        case [.control, .shift]: -1
        default: nil
        }
    }
}
