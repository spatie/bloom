import Foundation
import BloomCore

/// A diff turned into something worth sending someone.
///
/// The clipboard already carries the patch exactly as git wrote it, because that form is for
/// `git apply` and has to stay byte for byte. This one is for a person: the `diff --git` and
/// `index` lines are gone, the hunk ranges are rewritten as the line number a reader would scroll
/// to, and the whole thing is fenced as `diff` so Slack, GitHub and Linear all colour the plus and
/// minus lines. What survives is the part someone asked to see.
///
/// It is cut to a length a chat message can hold. A four thousand line patch pasted into a channel
/// is not shared, it is inflicted, and the reader scrolls past it to ask which file it was.
enum DiffShareText {
    /// Roughly a screenful in a chat client. Past this the message stops being read.
    private static let lineBudget = 120
    /// A minified bundle is one line of a hundred thousand characters, and the line budget alone
    /// would not catch it.
    private static let columnLimit = 200

    static func make(for file: ChangedFile, diff: FileDiff?) -> String {
        let heading = heading(for: file)

        guard !file.isBinary else {
            return "\(heading)\nBinary file, no text diff."
        }
        guard let diff, !diff.hunks.isEmpty else {
            return "\(heading)\nNo textual changes."
        }

        let (body, omitted) = body(of: diff)
        guard !body.isEmpty else {
            return "\(heading)\nNo textual changes."
        }

        var text = "\(heading)\n```diff\n\(body.joined(separator: "\n"))\n```"
        if omitted > 0 {
            text += "\n\(omitted.formatted()) more \(omitted == 1 ? "line" : "lines") not shown."
        }
        return text
    }

    /// What changed and by how much, in the same words the row in the file list uses.
    private static func heading(for file: ChangedFile) -> String {
        let renamedFrom = file.oldPath.flatMap { $0 == file.path ? nil : $0 }
        var parts = [renamedFrom.map { "\($0) -> \(file.path)" } ?? file.path]

        switch file.change {
        case .added, .untracked: parts.append("new file")
        case .deleted: parts.append("deleted")
        case .modified, .renamed, .copied: break
        }

        var counts: [String] = []
        if file.additions > 0 { counts.append("+\(file.additions)") }
        if file.deletions > 0 { counts.append("-\(file.deletions)") }
        if !counts.isEmpty { parts.append(counts.joined(separator: " ")) }

        return parts.joined(separator: "  ")
    }

    /// Whole hunks or none of them. A hunk cut off in the middle reads as a bug in whatever
    /// produced it, so the budget stops before a hunk rather than inside one. The exception is a
    /// first hunk that is longer than the whole budget, because dropping it would leave a message
    /// with nothing in it.
    private static func body(of diff: FileDiff) -> (lines: [String], omitted: Int) {
        var kept: [String] = []
        var omitted = 0

        for hunk in diff.hunks {
            // The `@@` line is scaffolding rather than a line of the file, so it never counts
            // towards what was left out.
            let rendered = render(hunk)

            if omitted > 0 {
                omitted += rendered.count - 1
                continue
            }
            if kept.isEmpty, rendered.count > lineBudget {
                kept = Array(rendered.prefix(lineBudget))
                omitted = rendered.count - lineBudget
                continue
            }
            guard kept.count + rendered.count <= lineBudget else {
                omitted = rendered.count - 1
                continue
            }
            kept += rendered
        }

        return (kept, omitted)
    }

    private static func render(_ hunk: DiffHunk) -> [String] {
        // The line number the reader would scroll to, rather than git's four number range. Nothing
        // downstream of a chat message is going to apply this. A hunk that only deletes has no
        // line in the new file, so it is named by where it used to be rather than as line zero.
        let start = hunk.newStart > 0 ? hunk.newStart : hunk.oldStart
        var lines = ["@@ line \(start)"]

        for line in hunk.lines {
            switch line.kind {
            case .context: lines.append(" \(clip(line.text))")
            case .addition: lines.append("+\(clip(line.text))")
            case .deletion: lines.append("-\(clip(line.text))")
            case .noNewline: break
            }
        }
        return lines
    }

    private static func clip(_ text: String) -> String {
        guard text.count > columnLimit else { return text }
        return "\(text.prefix(columnLimit))…"
    }
}
