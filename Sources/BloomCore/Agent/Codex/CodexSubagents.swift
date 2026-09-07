import Foundation

/// One app-server connection carries the parent and its children. Child completions must never
/// finish the parent's turn, and only children announced by this family may be read in its UI.
public struct CodexSubagents: Sendable {
    private var children: [String: CodexSubAgentActivity] = [:]
    private var seenActivities: Set<String> = []

    public init() {}

    public func contains(threadID: String) -> Bool { children[threadID] != nil }

    public func threadID(for id: SubagentID) -> String? {
        children.keys.first { Self.id(for: $0) == id }
    }

    public static func id(for threadID: String) -> SubagentID { SubagentID("codex:\(threadID)") }

    public mutating func receive(_ event: CodexEvent, parentThreadID: String) -> [SubagentSignal] {
        guard let source = event.threadID,
              source == parentThreadID || contains(threadID: source) else { return [] }
        switch event {
        case .itemStarted(let item), .itemCompleted(let item):
            guard case .subAgentActivity(let activity) = item.item,
                  !activity.agentThreadID.isEmpty, activity.agentThreadID != parentThreadID,
                  seenActivities.insert(activity.id).inserted else { return [] }
            var signals: [SubagentSignal] = []
            if children[activity.agentThreadID] == nil {
                children[activity.agentThreadID] = activity
                signals.append(.started(start(activity)))
            }
            if activity.kind == "completed" || activity.kind == "interrupted" {
                signals.append(.reported(SubagentReport(
                    id: Self.id(for: activity.agentThreadID), status: activity.kind, summary: ""
                )))
            }
            return signals
        case .turnStarted(let turn):
            guard let child = children[turn.threadID] else { return [] }
            return [.started(start(child, resumesExisting: true))]
        case .turnCompleted(let turn):
            guard contains(threadID: turn.threadID) else { return [] }
            return [.reported(SubagentReport(
                id: Self.id(for: turn.threadID), status: turn.status.rawValue,
                summary: turn.errorMessage ?? ""
            ))]
        default:
            return []
        }
    }

    private func start(_ child: CodexSubAgentActivity, resumesExisting: Bool = false) -> SubagentStart {
        SubagentStart(
            id: Self.id(for: child.agentThreadID), toolUseID: child.id,
            description: child.agentPath.split(separator: "/").last.map(String.init) ?? "Codex subagent",
            type: "Codex", isBackgrounded: true,
            resumesExisting: resumesExisting
        )
    }
}
