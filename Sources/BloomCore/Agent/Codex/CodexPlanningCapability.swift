import Foundation

public enum CodexPlanningCapability {
    public static let unavailableKey = "codex.planning.unavailable"
    public static let rescanKey = "codex.planning.rescan"
    public static let explanation = "This Codex version does not support Plan. Update Codex, then check again."

    public static func isUnsupportedField(_ error: CodexRPCError) -> Bool {
        let message = error.message.lowercased()
        return error.code == -32602 && message.contains("collaborationmode")
            && ["unknown field", "unrecognized field", "unrecognised field", "unsupported field",
                "not supported", "unavailable", "experimental"].contains(where: message.contains)
    }
}
