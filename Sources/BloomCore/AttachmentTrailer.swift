import Foundation

/// The plain words a prompt carries its attachments in, written and read back in one place.
///
/// When a turn is sent, the files attached to it are named in the prompt text as a short trailer:
///
///     look at this
///
///     Attached file:
///     - .bloom/attachments/9JVKW4/IMG_4395.jpeg
///
/// That is what the agent receives and it is not going to change. Every agent Bloom can run reads
/// files by path, so a path in the text works for Claude Code and for Codex with nothing
/// conditional anywhere, and encoding images as content blocks would be Claude Code's own protocol
/// and leave every other agent looking at an empty message.
///
/// Bloom does not have to *draw* it that way, though, and a list of paths in a speech bubble is a
/// worse answer than the chips the composer showed a second earlier. So the transcript takes the
/// trailer back off before it renders, which is why `split` exists and why it lives in the same
/// file as `compose`: the two are one format, and a parser kept anywhere else drifts from the
/// generator the first time either is touched.
///
/// `split` is deliberately strict. It only recognises the exact shape `compose` writes, down to
/// the blank line, the singular against the plural, and the body having no trailing whitespace of
/// its own, and it returns the text untouched at the first thing that does not fit. Parsing prose
/// is how you end up eating a line of somebody's actual message, and the cost of being wrong here
/// is a sentence the user wrote disappearing from their own transcript.
///
/// It is still parsing. Someone who ends a message with a correctly pluralised "Attached files:"
/// and a well formed list of paths gets chips, and if those paths are not files the chips will say
/// so. That is the residual risk of reading the text rather than storing the attachments beside
/// it, and it is the reason a structured column is the better answer the day the sending path is
/// free to be changed.
public enum AttachmentTrailer {
    /// The header, which says how many there are so a reader is not left counting bullets.
    public static let singular = "Attached file:"
    public static let plural = "Attached files:"

    /// The prompt the agent actually receives.
    public static func compose(text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }

        let header = paths.count == 1 ? singular : plural
        let list = paths.map { "- \($0)" }.joined(separator: "\n")
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A prompt of nothing but attachments is allowed: dropping a screenshot and pressing send
        // is a sentence in itself, and refusing it would make the user type a word for the sake of
        // the guard rather than for the agent.
        guard !body.isEmpty else { return "\(header)\n\(list)" }
        return "\(body)\n\n\(header)\n\(list)"
    }

    /// What was typed and what was attached, given what was sent.
    ///
    /// Returns the text unchanged and no paths whenever the tail is not exactly what `compose`
    /// writes. Round trips: `split(compose(text: t, paths: p))` is `(t.trimmed, p)` for every
    /// `t` and non-empty `p`.
    public static func split(_ text: String) -> (body: String, paths: [String]) {
        let lines = text.components(separatedBy: "\n")

        // The trailer is always the tail, so the header is looked for from the end. An earlier
        // one belongs to the body: a message can quote a previous turn.
        guard let header = lines.lastIndex(where: { $0 == singular || $0 == plural }) else {
            return (text, [])
        }

        let listed = lines[(header + 1)...]
        guard !listed.isEmpty else { return (text, []) }

        var paths: [String] = []
        for line in listed {
            guard line.hasPrefix("- ") else { return (text, []) }
            let path = String(line.dropFirst(2))
            // No padding either side. `compose` writes the path and nothing else, so anything
            // else here is a bullet list somebody typed.
            guard !path.isEmpty,
                  path == path.trimmingCharacters(in: .whitespaces) else { return (text, []) }
            paths.append(path)
        }

        // The header counts, so a header that disagrees with the list was written by hand.
        guard lines[header] == (paths.count == 1 ? singular : plural) else { return (text, []) }

        let before = lines[..<header]
        // Attachments with nothing said about them, which is a turn in its own right.
        guard !before.isEmpty else { return ("", paths) }

        // One blank line between the body and the trailer, exactly as `compose` writes it.
        guard before.last == "" else { return (text, []) }
        let body = before.dropLast().joined(separator: "\n")

        // `compose` trims the body, so anything still hanging off either end means these words
        // and this list were not written together.
        guard body == body.trimmingCharacters(in: .whitespacesAndNewlines) else { return (text, []) }
        return (body, paths)
    }
}
