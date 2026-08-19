import AppKit

/// Putting text on the pasteboard, in one place.
///
/// Two lines, written out nine times: a branch name, a file path in three different rows, a pull
/// request link, a code block, a raw event, a workspace name in a menu. Two lines are not much,
/// but `clearContents()` is easy to leave out and a pasteboard that was not cleared keeps whatever
/// richer flavour was on it before, so a paste can land as the thing copied three actions ago.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// How long a "Copied" label stays up.
    ///
    /// One number, because three buttons show that label and two of them used to hold it for 1.2
    /// seconds while the third held it for 1.5.
    static let flashDuration: Duration = .seconds(1.5)
}
