import Foundation

/// The installer's own account of an uninstall, which is what the result screen shows. The plan
/// said what would happen; this says what did, including anything that had to be left in place.
public struct ServerUninstallOutcome: Sendable, Equatable {
    public var unchanged: Bool
    public var removed: [String]
    public var kept: [String]
    public var deletedData: Bool
    public var message: String

    public init(unchanged: Bool, removed: [String], kept: [String], deletedData: Bool, message: String) {
        self.unchanged = unchanged; self.removed = removed; self.kept = kept
        self.deletedData = deletedData; self.message = message
    }

    /// Nil for anything but a completion that carries the lists, so an older installer that does
    /// not know `--uninstall` can never be reported as having removed something.
    public init?(event: ServerInstallEvent) {
        guard event.event == "complete", let removed = event.removed, let kept = event.kept else { return nil }
        self.init(unchanged: event.unchanged ?? removed.isEmpty, removed: removed, kept: kept,
                  deletedData: event.deletedData ?? false,
                  message: event.message ?? (removed.isEmpty ? "Nothing was changed." : "Bloom Server was removed."))
    }

    public var title: String { unchanged ? "Nothing to uninstall" : "Bloom Server uninstalled" }

    public static let removalPrompt = "Its saved connection and sidebar entry are removed from this Mac. Local drafts and SSH keys stay."
}
