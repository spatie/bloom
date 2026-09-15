import Foundation

/// The one warning a workspace shows when its settings files had entries that were skipped.
///
/// One notice however many issues there are, because each one is the same instruction, which is
/// to open the file, and a stack of them would push the conversation down the window. The first
/// two sentences are shown and the rest counted: enough to see what kind of mistake it is, and
/// the file says the rest.
public struct SettingsIssuesNotice: Sendable, Hashable {
    public var title: String
    public var messages: [String]
    /// The file Open File opens, which is the first issue's.
    public var path: String
    public var line: Int?
    /// What a dismissal is remembered against. A different set of messages is a different notice,
    /// so fixing one entry and breaking another asks to be read again.
    public var signature: [String]

    static let shownMessages = 2

    public static func make(issues: [SettingsIssue]) -> SettingsIssuesNotice? {
        guard let first = issues.first else { return nil }
        let files = Set(issues.map(\.path))
        let place = files.count == 1 ? displayName(of: first.path) : "the settings files"

        let title: String
        if issues.count == 1, first.entry == .file {
            title = "\(place) could not be read"
        } else {
            let entries = issues.count == 1 ? "1 entry" : "\(issues.count) entries"
            let verb = issues.count == 1 ? "was" : "were"
            title = "\(entries) in \(place) \(verb) skipped"
        }

        var messages = issues.prefix(shownMessages).map(\.message)
        let rest = issues.count - messages.count
        if rest > 0 { messages.append(rest == 1 ? "And 1 more." : "And \(rest) more.") }

        return SettingsIssuesNotice(
            title: title,
            messages: messages,
            path: first.path,
            line: first.line,
            signature: issues.map { "\($0.path)\n\($0.message)" }
        )
    }

    /// `.bloom/settings.toml` rather than the absolute path, which is the same few directories for
    /// every workspace of the project and pushes the part that says which file off the end.
    static func displayName(of path: String) -> String {
        let components = (path as NSString).pathComponents
        return components.suffix(2).joined(separator: "/")
    }
}
