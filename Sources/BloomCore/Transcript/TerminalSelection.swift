import Foundation

/// Lines selected in a terminal pane, on their way into the composer as an attachment.
///
/// **A file rather than a quoted paragraph**, for the reason a failed check's log is one: what
/// somebody selects in a shell is a stack trace or a screen of test output far more often than it
/// is one line, and a draft holding two hundred lines of it is a draft nobody can edit before
/// sending. As a file it is a chip naming the terminal it came from, and the agent reads it when
/// it needs to.
///
/// There is no line range on the chip, and that is deliberate rather than missing. A pane kept
/// alive across launches runs inside tmux, which holds the real scrollback, so the row numbers the
/// terminal view knows about are positions on a screen that has already been redrawn, and a range
/// the agent could not find again is worse than none.
public enum TerminalSelection {
    /// The selection as it should be handed over, or nil when there is nothing in it.
    ///
    /// A terminal pads every row out to the width of the screen, so a selection dragged across a
    /// few lines arrives with a run of spaces on the end of each. Those go, and so do blank rows at
    /// either end, which is what a drag that starts or stops a little past the text picks up.
    /// Indentation inside the selection is left alone: in a traceback or a YAML error it is what
    /// the text means.
    public static func text(_ selection: String) -> String? {
        var lines = selection
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return String(line)
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The name the attachment is written under, which is also what its chip says: the terminal's
    /// tab title, then when, the way a pasted picture is named.
    ///
    /// The title is whatever the tab is called, which a rename makes anything at all, so it is
    /// cleaned the way a check's name is before it becomes a filename.
    public static func filename(terminal title: String, at date: Date = .now, timeZone: TimeZone = .current) -> String {
        let label = PastedAttachment.label(title, fallback: "Terminal")
        return "\(label) \(PastedAttachment.timestamp(date, in: timeZone)).txt"
    }
}
