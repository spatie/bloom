import Foundation

/// A chat's identity is stable while the reader moves focus. The active pane is an explicit
/// alternative, never a fallback when the chat has been closed or is only a sidebar subagent.
public enum PaneSplitAnchor: Sendable, Equatable {
    case chat(SessionID)
    case activePane

    public struct Tab: Sendable {
        public var root: PaneContent
        public var layout: SplitLayout
        public var contents: [String: PaneContent]

        public init(root: PaneContent, layout: SplitLayout, contents: [String: PaneContent]) {
            self.root = root
            self.layout = layout
            self.contents = contents
        }
    }

    public struct Destination: Sendable, Equatable {
        public var tab: PaneContent
        public var pane: String
    }

    public func resolve(in tabs: [Tab], selected: PaneContent?) -> Destination? {
        switch self {
        case .activePane:
            guard let tab = tabs.first(where: { $0.root == selected }) else { return nil }
            return Destination(tab: tab.root, pane: tab.layout.focus)
        case .chat(let sessionID):
            // A chat can be displayed twice. Prefer its focused copy, but never a focused
            // terminal or another chat simply because it happens to share the containing tab.
            let ordered = tabs.filter { $0.root == selected } + tabs.filter { $0.root != selected }
            for tab in ordered {
                let panes = [tab.layout.focus] + tab.layout.panes.filter { $0 != tab.layout.focus }
                if let pane = panes.first(where: { tab.contents[$0] == .chat(sessionID) }) {
                    return Destination(tab: tab.root, pane: pane)
                }
            }
            return nil
        }
    }
}
