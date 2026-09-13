import Foundation

public enum InteractionModeFailure: Error, LocalizedError, Sendable {
    case unsupported
    case missingModel

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This Codex version does not support Plan mode. Update Codex or switch to Build."
        case .missingModel: "Choose a Codex model before changing the work mode."
        }
    }

    /// Only local validation and JSON-RPC's explicit request rejection prove a turn was not
    /// accepted. A timeout, connection loss or provider internal error remains uncertain.
    public static func isDefinitiveTurnRejection(_ error: any Error) -> Bool {
        if error is InteractionModeFailure { return true }
        guard let rpc = error as? CodexRPCError else { return false }
        return rpc.code == -32602 || rpc.code == -32601
    }
}
