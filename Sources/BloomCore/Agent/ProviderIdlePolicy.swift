import Foundation

public enum ProviderIdlePolicy {
    public static let settingKey = "agents.idleProcessMinutes"
    public static let choices = [0, 15, 30, 60, 120]
    /// Opt in: restarting a provider trades memory for startup time and process-local grants.
    public static func duration(stored: String?) -> Duration? {
        guard let value = stored.flatMap(Int.init), choices.contains(value), value > 0 else { return nil }
        return .seconds(value * 60)
    }
}

public enum ProviderIdleError: Error, Sendable {
    case retired
}
