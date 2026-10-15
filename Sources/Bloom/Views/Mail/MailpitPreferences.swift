import SwiftUI
import BloomCore

/// Incoming mail settings, as a view reads and writes them.
///
/// One declaration of the `@AppStorage` lines, so the keys and defaults are spelled once
/// for every view that edits them, which today is Settings > Incoming mails. Nothing here tells
/// `Mailbox` they changed: it listens for that itself.
struct MailpitPreferences: DynamicProperty {
    @AppStorage(MailpitSettings.enabledKey) var isEnabled = MailpitSettings.isOnByDefault
    @AppStorage(MailpitSettings.smtpPortKey)
    var smtpPort = MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier).smtp
}
