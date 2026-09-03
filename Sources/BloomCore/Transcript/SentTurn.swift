import Foundation

/// Instructions Bloom put into a turn it composed, in the words the agent was actually handed.
///
/// Bloom writes four kinds of instruction into the turns it sends on the owner's behalf, and
/// three of them are normally a file: `PullRequestInstructions`, `ConflictInstructions` and a
/// project's own words through `ProjectInstructions`. A file is named in the sentence that asks
/// for it, `FileMention` finds the path there, and the transcript already draws it as a chip the
/// reader can point at. The fourth, `MergeInstructions`, is never a file and must not become one:
/// its head says why, and the short version is that somebody watching a server being changed has
/// to be able to see the rules without opening something git will not report.
///
/// So the words are here instead, and this is what a chip stands for when there is no path to
/// name. It is the same object the file case produces, with a body where that one has a path.
public struct InjectedInstruction: Equatable, Sendable {
    /// What the chip reads. A block that is in the message has no filename to borrow, and the
    /// reader still has to be told which of the four this one is.
    public var title: String
    /// The words themselves, exactly as they went down the wire. Never a summary: the whole point
    /// of being able to look is to find out what the agent was told.
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// What a turn that has already been sent is made of, as the transcript draws it.
///
/// Three runs, and the last two are one thing said two ways. A file Bloom named in the sentence is
/// a path the reader can point at; a block of instructions Bloom put in the message itself is
/// words the reader can point at. **One chip type takes either**, which is the whole of this type:
/// the alternative was a pill inside the sentence for the file kinds and a button with a popover
/// under the bubble for the inline kind, which is what was here, and the owner's report about it
/// was that he could hover one and not the other. Two drawings of "here is what Bloom added to
/// your message" is one drawing too many.
///
/// **The blocks are recognised byte for byte and are left in the text.** Nothing is stripped: the
/// segments joined back together are the turn exactly as it was stored, which is what makes a
/// selection copy out as the message that was sent, and what makes a transcript reloaded from the
/// database read the same as one that is still on screen. The old shape lifted the merge rules out
/// of the text and handed them to the row beside it, so the bubble was drawn from a string that
/// was never sent to anybody.
///
/// The parsing is a pure function of the stored text and of the constants Bloom appends, so it
/// needs no worktree, no store and no memory of the press that composed the turn.
public enum SentTurn {
    /// One run of a sent turn.
    public enum Segment: Equatable, Sendable {
        case text(String)
        /// A file named in the sentence, without the backticks that delimit it. `FileMention`
        /// decides what counts.
        case file(String)
        /// A block Bloom appended whole.
        case instructions(InjectedInstruction)

        /// The literal text of this run. `segments(in: t).map(\.text).joined() == t`, for every
        /// turn there is.
        public var text: String {
            switch self {
            case .text(let words): words
            case .file(let path): AttachmentDraft.token(for: path)
            case .instructions(let block): block.body
            }
        }
    }

    /// What each kind of block is called on the chip that stands for it.
    ///
    /// Named after the button that composed the turn rather than after the file it would have been
    /// written to, because the reader pressed the button and never sees the file.
    public static let mergeTitle = "Merge instructions"
    public static let pullRequestTitle = "Pull request instructions"
    public static let conflictTitle = "Conflict instructions"
    public static let projectTitle = "Project instructions"

    public static func segments(in text: String) -> [Segment] {
        var out: [Segment] = []
        var start = text.startIndex

        while let found = firstBlock(in: text, from: start) {
            out += words(String(text[start..<found.range.lowerBound]))
            out.append(.instructions(found.block))
            start = found.range.upperBound
        }
        out += words(String(text[start...]))
        return out
    }

    /// The turn with every injected block taken out of it: what the message says on its own.
    ///
    /// For the one reader that has a line rather than a bubble to put a turn in, which is the
    /// transcript's navigation control. A bubble draws the blocks as chips and needs them left
    /// where they are; a summary one line long has room for the sentence the owner asked for and
    /// nothing else, and a merge turn summarised as the first line of the rules about `--admin`
    /// says nothing about which pull request it was.
    public static func withoutInstructions(_ text: String) -> String {
        segments(in: text)
            .compactMap { segment -> String? in
                if case .instructions = segment { return nil }
                return segment.text
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Finding a block

    /// Every block Bloom ever appends whole, as the constant it is appended from.
    ///
    /// Three of these four are a fallback rather than the usual road: a pull request's and a
    /// conflict's instructions go into the message only when the file could not be written, which
    /// a read-only checkout is. They are listed all the same, because that turn is exactly the one
    /// whose reader has the least idea what the agent was given.
    ///
    /// `retiredDefaults` is in here for the reason it exists at all: a turn sent by an older Bloom
    /// is still in the database and still has to be readable.
    private static let constants: [InjectedInstruction] = {
        var found = [
            InjectedInstruction(title: mergeTitle, body: MergeInstructions.canonical),
            InjectedInstruction(
                title: pullRequestTitle, body: PullRequestInstructions.defaultMarkdown
            ),
            InjectedInstruction(title: conflictTitle, body: ConflictInstructions.defaultMarkdown),
        ]
        found += PullRequestInstructions.retiredDefaults.map {
            InjectedInstruction(title: pullRequestTitle, body: $0)
        }
        return found
    }()

    private struct Found {
        var range: Range<String.Index>
        var block: InjectedInstruction
    }

    /// The first block at or after `from`, or nothing.
    ///
    /// Every candidate is searched for and the earliest wins, rather than the list being walked in
    /// order, because a merge turn carries two of them and they arrive in the order the agent
    /// reads them rather than in the order they are declared here.
    private static func firstBlock(in text: String, from start: String.Index) -> Found? {
        var best: Found?
        func keep(_ candidate: Found) {
            guard let current = best else {
                best = candidate
                return
            }
            if candidate.range.lowerBound < current.range.lowerBound { best = candidate }
        }

        for block in constants {
            guard let range = text.range(of: block.body, range: start..<text.endIndex),
                  startsABlock(range.lowerBound, in: text)
            else { continue }
            keep(Found(range: range, block: block))
        }

        // A project's own words are not a constant, so what is recognised is the sentence Bloom
        // puts in front of them. That sentence stays as prose and the chip covers the words after
        // it, which is the same shape the file case has: a sentence saying what is attached, and
        // then the thing itself. It runs to the end of the turn because `ProjectInstructions.turn`
        // appends it last and nothing follows it.
        for subject in ProjectInstructions.Subject.allCases {
            let lead = ProjectInstructions.inlineLead(for: subject) + "\n\n"
            guard let range = text.range(of: lead, range: start..<text.endIndex),
                  startsABlock(range.lowerBound, in: text)
            else { continue }
            let body = String(text[range.upperBound...])
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            keep(Found(
                range: range.upperBound..<text.endIndex,
                block: InjectedInstruction(title: projectTitle, body: body)
            ))
        }

        return best
    }

    /// Whether a match begins a paragraph of its own, which is the whole of what stops an ordinary
    /// message being read as one of these.
    ///
    /// Bloom joins the parts of a turn with a blank line and never with anything else, so a match
    /// that starts mid sentence is somebody quoting rather than Bloom appending. It is the same
    /// test the merge rules were recognised by before there were four kinds of them.
    private static func startsABlock(_ index: String.Index, in text: String) -> Bool {
        guard index != text.startIndex else { return true }
        guard let breakStart = text.index(index, offsetBy: -2, limitedBy: text.startIndex),
              breakStart < index
        else { return false }
        return text[breakStart..<index] == "\n\n"
    }

    /// A run of the turn that holds no injected block, as words and the files named in them.
    private static func words(_ run: String) -> [Segment] {
        guard !run.isEmpty else { return [] }
        return FileMention.segments(in: run).map { segment in
            switch segment {
            case .text(let words): .text(words)
            case .attachment(let path): .file(path)
            }
        }
    }
}
