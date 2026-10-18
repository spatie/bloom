import Foundation

/// The app-owned inbox ports and the user's SMTP port choice.
///
/// The keys are here rather than in the settings pane so that the pane's `@AppStorage` and the
/// `Mailbox` reading them at launch cannot disagree about a spelling.
public enum MailpitSettings {
    public static let enabledKey = "mailpit.enabled"
    public static let smtpPortKey = "mailpit.smtpPort"

    public struct Ports: Equatable, Sendable {
        public let smtp: Int
        public let api: Int

        public init(smtp: Int, api: Int) {
            self.smtp = smtp
            self.api = api
        }
    }

    /// The Dev app gets different ports, so it cannot claim the production app's listeners.
    /// An unbundled run is treated as development for the same reason.
    public static func bundledPorts(forBundleIdentifier identifier: String?) -> Ports {
        identifier == Store.primaryBundleIdentifier
            ? Ports(smtp: 2255, api: 8025)
            : Ports(smtp: 2256, api: 8026)
    }

    public static func bundledAddress(forBundleIdentifier identifier: String?) -> String {
        "http://127.0.0.1:\(bundledPorts(forBundleIdentifier: identifier).api)"
    }

    /// Ports below 1024 need privileges. The API listener stays fixed and cannot share its port
    /// with SMTP. Validation is shared by Settings and the process manager.
    public static func isValidSMTPPort(_ port: Int, forBundleIdentifier identifier: String?) -> Bool {
        isValidSMTPPort(port, forAPIport: bundledPorts(forBundleIdentifier: identifier).api)
    }

    public static func isValidSMTPPort(_ port: Int, forAPIport apiPort: Int) -> Bool {
        (1024...65535).contains(port) && port != apiPort
    }

    /// A copy without a saved choice can receive test mail immediately. An explicit Off choice
    /// stays in UserDefaults and still prevents the server from opening a port.
    public static let isOnByDefault = true

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? isOnByDefault
    }
}
