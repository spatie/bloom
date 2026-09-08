import Foundation

/// Local builds and probes must not turn intentional crashes into production incidents.
/// The preference is separate from install counting because these reports contain stack traces.
public enum CrashReporting {
    public static let settingKey = "sendCrashReports"
    public static let isOnByDefault = true
    public static let probeBundleIdentifier = "be.spatie.bloom.flare-probe"

    public static func isEligible(
        bundleIdentifier: String?, identity: BuildIdentity, enabled: Bool, debuggerAttached: Bool
    ) -> Bool {
        guard enabled, !debuggerAttached, bundleIdentifier == "be.spatie.bloom" else { return false }
        switch identity {
        case .release, .master: return true
        case .local: return false
        }
    }

    public static func environment(for identity: BuildIdentity) -> String {
        switch identity {
        case .release: "production"
        case .master: "development"
        case .local: "testing"
        }
    }
}
