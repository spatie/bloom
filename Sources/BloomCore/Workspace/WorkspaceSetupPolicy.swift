import Foundation

/// Setup at creation is either owned by the app, awaited by a headless caller, or declined.
/// Skipping belongs to this request, never to the project's settings or a later manual run.
public enum WorkspaceSetupPolicy: Sendable {
    case deferred
    case run
    case skip

    public func initialState(script: String?) -> SetupState {
        guard self != .skip,
              let script,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skipped
        }
        return .pending
    }
}
