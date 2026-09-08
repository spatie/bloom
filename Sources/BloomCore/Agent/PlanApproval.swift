import Foundation

/// Approving a plan also chooses how implementation runs. A bare allow leaves a CLI launched
/// in plan mode falling back to `default`, which asks again for every file edit.
public enum PlanApproval {
    public static let modes: [PermissionMode] = [.acceptEdits, .auto, .bypassPermissions]

    public static func implementationMode(_ mode: PermissionMode) -> PermissionMode {
        switch mode {
        case .autoReview: .auto
        case .plan: .acceptEdits
        case .acceptEdits, .auto, .bypassPermissions: mode
        }
    }

    public static func modeKey(sessionID: SessionID) -> String {
        "session.\(sessionID).implementationPermissionMode"
    }

    /// Stored on the question so recycling a transcript cell cannot reset the offered mode,
    /// and a reloaded transcript shows the same choice the person was asked to approve.
    public static func preparing(_ ask: PermissionAsk, mode: PermissionMode) -> PermissionAsk {
        guard ask.isPlanApproval else { return ask }
        var prepared = ask
        let mode = implementationMode(mode)
        prepared.implementationMode = mode
        if case .object(var json) = JSONValue.parse(String(decoding: ask.raw, as: UTF8.self)) {
            json["bloom_implementation_mode"] = .string(mode.rawValue)
            if let data = try? JSONEncoder().encode(JSONValue.object(json)) { prepared.raw = data }
        }
        return prepared
    }

    public static func approvedMode(storedDecision: String) -> PermissionMode? {
        let prefix = "approve-plan-"
        guard storedDecision.hasPrefix(prefix),
              let mode = PermissionMode(rawValue: String(storedDecision.dropFirst(prefix.count))),
              modes.contains(mode) else { return nil }
        return mode
    }

    public static let keepPlanningMessage =
        "The plan is not approved yet. Stay in plan mode and ask what should change before implementing."
}

enum PlanApprovalError: Error {
    case invalidDecision
}
