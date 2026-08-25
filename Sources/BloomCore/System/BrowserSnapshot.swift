import Foundation

/// What a picture taken of the browser pane is called.
///
/// Here rather than beside the button, because a filename is the whole of what the user sees of an
/// attachment once it is a chip in the composer, and it is the one part of this feature that has a
/// right and a wrong answer worth asserting on. The button is a button.
///
/// The shape is `PastedAttachment.filename`'s, deliberately: a screenshot copied off the clipboard
/// and a screenshot taken of the pane both land in `.bloom/attachments`, both are pictures of a
/// screen, and two conventions for naming the same thing would sort the folder into two halves.
/// What is added is where the picture came from, because a page has an address and a clipboard has
/// nothing, and "which of these four shots was the settings screen" is the question the chip has to
/// answer without being opened.
public enum BrowserSnapshot {
    /// The most of the address that goes in the name.
    ///
    /// Long enough for a host, a port and a route, short enough that the chip in the composer still
    /// shows the date. Past this the tail is dropped rather than the head, because a host is what
    /// tells two workspaces' dev servers apart and the deepest path segment rarely is.
    static let maxLabelLength = 40

    /// How wide a picture taken for an agent is rendered, in points.
    ///
    /// The camera button captures at the pane's own width, so the reader gets back exactly what
    /// they were looking at. A capture that goes to a model is paid for by the token instead, and
    /// a model reading a page does not need a retina copy of it: 900 points across is wide enough
    /// for body text to stay legible and keeps a full pane comfortably under
    /// `BridgeToolImage.maximumBytes`, where the pane's own retina width can be four times the
    /// bytes for nothing anybody reads.
    public static let agentWidth: Double = 900

    /// The file a page captured now is written as.
    public static func filename(
        for address: String,
        at date: Date = .now,
        avoiding taken: Set<String> = [],
        timeZone: TimeZone = .current
    ) -> String {
        let label = self.label(for: address)
        let stamp = PastedAttachment.timestamp(date, in: timeZone)
        let name = label.isEmpty ? "Page \(stamp).png" : "\(label) \(stamp).png"
        return PastedAttachment.uniqued(name, avoiding: taken)
    }

    /// The address as a run of characters a filename can hold: host, port and path, with every
    /// separator turned into a hyphen.
    ///
    /// A colon and a slash are both rewritten by the Finder behind the user's back, so neither can
    /// survive here. The scheme and the query string are dropped: `https` is true of every page
    /// this pane can show and says nothing, and a query string is usually longer than the rest of
    /// the address put together.
    public static func label(for address: String) -> String {
        guard let components = URLComponents(string: address), let host = components.host else {
            return ""
        }
        var label = host
        if let port = components.port { label += "-\(port)" }

        let path = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if !path.isEmpty { label += "-\(path)" }

        // Anything left that a path separator or a leading dot could be made of. `safeFilename`
        // does the same job for a file that already had a name; this is a name being invented, so
        // it is cheaper to keep only what is known to be harmless.
        label = String(label.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-._".unicodeScalars.contains(scalar)
                ? Character(scalar)
                : "-"
        })
        while label.hasPrefix("-") || label.hasPrefix(".") { label.removeFirst() }
        while label.hasSuffix("-") || label.hasSuffix(".") { label.removeLast() }

        return String(label.prefix(maxLabelLength))
    }
}
