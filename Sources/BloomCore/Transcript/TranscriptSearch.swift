import Foundation

/// One indexed transcript row that matched, and where in the app it is.
///
/// It carries a session and a sequence number as well as a workspace because a result that only
/// said "this workspace" would leave the reader scrolling a four thousand row transcript looking
/// for the sentence they were just shown. See `TranscriptSearchTarget`.
public struct TranscriptMatch: Sendable, Hashable, Identifiable {
    public var id: Int64 { messageID }
    public var messageID: Int64
    public var workspaceID: WorkspaceID
    public var sessionID: SessionID
    public var sessionTitle: String
    public var seq: Int
    public var kind: MessageKind
    public var createdAt: Date
    public var snippet: TranscriptSnippet
    /// bm25, which is negative and smaller when better. Kept as SQLite hands it over rather than
    /// flipped, so a change of ranking function here does not silently invert every comparison.
    public var score: Double

    public init(
        messageID: Int64,
        workspaceID: WorkspaceID,
        sessionID: SessionID,
        sessionTitle: String,
        seq: Int,
        kind: MessageKind,
        createdAt: Date,
        snippet: TranscriptSnippet,
        score: Double
    ) {
        self.messageID = messageID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.seq = seq
        self.kind = kind
        self.createdAt = createdAt
        self.snippet = snippet
        self.score = score
    }
}

/// Every match in one workspace, which is what a row of the search screen is.
///
/// **A result is a workspace, not a message.** The question being asked is "which workspace was
/// it", and a workspace where the agent said "WAL" forty times would otherwise take forty of the
/// first fifty rows and bury the four other workspaces that are the actual answer. So the matches
/// are folded into their workspace, the best few are shown underneath it, and `total` says how
/// many more there were.
public struct TranscriptWorkspaceMatches: Sendable, Hashable, Identifiable {
    public var id: WorkspaceID { workspaceID }
    public var workspaceID: WorkspaceID
    /// Best first, capped at `TranscriptSearch.matchesPerWorkspace`.
    public var matches: [TranscriptMatch]
    /// Every match in this workspace, including the ones not in `matches`.
    public var total: Int

    public var best: TranscriptMatch? { matches.first }

    public init(workspaceID: WorkspaceID, matches: [TranscriptMatch], total: Int) {
        self.workspaceID = workspaceID
        self.matches = matches
        self.total = total
    }
}

/// Where a result sends the reader: a workspace, the session inside it, and the row.
public struct TranscriptSearchTarget: Sendable, Hashable {
    public var workspaceID: WorkspaceID
    public var sessionID: SessionID
    public var seq: Int

    public init(workspaceID: WorkspaceID, sessionID: SessionID, seq: Int) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.seq = seq
    }
}

/// A line of context with the matched words marked, ready to be drawn and nothing more.
///
/// Segments rather than ranges into a string. A `Range<String.Index>` handed to a view has to be
/// applied to the exact string it came from or it traps, and the string it came from crosses an
/// actor and a diffing pass on its way to the screen. A segment cannot be applied to the wrong
/// thing.
public struct TranscriptSnippet: Sendable, Hashable {
    public struct Segment: Sendable, Hashable {
        public var text: String
        public var isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var text: String { segments.map(\.text).joined() }
    public var isEmpty: Bool { segments.allSatisfy { $0.text.isEmpty } }
}

/// Turning what was typed into something FTS5 will accept, and turning what it hands back into
/// something a view can draw.
///
/// All of it lives here rather than in `Store` or in the search screen because every one of these
/// is a decision with an edge case behind it, and `Tests/BloomCoreTests` can only reach the core.
public enum TranscriptSearch {
    /// Below this the query is treated as not yet typed. One letter matches a sizeable fraction of
    /// every transcript ever written, and running it on the keystroke that produced it is a
    /// hundred thousand rows of work thrown away by the next keystroke.
    public static let minimumQueryLength = 2

    /// How many rows of one workspace are shown before the rest become a count.
    public static let matchesPerWorkspace = 3

    /// How deep into the ranked list the grouping looks. Far enough that a workspace whose best
    /// match is mediocre still appears, small enough that the join and the snippet building stay
    /// off the main thread's critical path.
    public static let candidateLimit = 400

    /// The characters FTS5 is asked to wrap a match in, and which `snippet(from:)` reads back.
    ///
    /// Control characters rather than `<b>` or `**`, because the thing being wrapped is arbitrary
    /// transcript text: a session that discusses HTML would otherwise have its own markup read as
    /// a highlight. STX and ETX cannot appear in a payload that came off a JSON line.
    public static let openMark = "\u{02}"
    public static let closeMark = "\u{03}"

    /// What the user typed, as an FTS5 MATCH expression, or nil when there is nothing to run.
    ///
    /// Everything is quoted. FTS5's query language has `AND`, `OR`, `NOT`, `NEAR`, `*`, `^`, `:`
    /// and parentheses in it, and a person typing a search does not know that: `Store.swift:1881`
    /// is a column filter as far as FTS5 is concerned, and `a - b` is a syntax error that came
    /// back to the screen as "no results" with no way to tell the two apart. Quoting turns all of
    /// it back into words.
    ///
    /// A phrase in double quotes survives as a phrase, because that is the one piece of query
    /// syntax people do expect to work, and it is the difference between finding a sentence and
    /// finding two words in the same message.
    ///
    /// The last word gets a prefix star so that results appear while the word is still being
    /// typed. Only the last, and only when the query does not end in a space: "wal thin" should
    /// find "thinking", but once the space is typed the user has finished that word and a search
    /// for a prefix of it is a search for something they did not ask for.
    public static func matchExpression(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength else { return nil }

        let tokens = tokens(in: trimmed)
        guard !tokens.isEmpty else { return nil }

        let endsMidWord = !(query.last?.isWhitespace ?? true) && !(query.hasSuffix("\""))
        return tokens.enumerated()
            .map { index, token in
                let quoted = "\"" + token.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let isLast = index == tokens.count - 1
                return isLast && endsMidWord && !token.wasQuoted ? quoted + "*" : quoted
            }
            .joined(separator: " AND ")
    }

    private struct Token {
        var text: String
        var wasQuoted: Bool
    }

    /// Splits on whitespace, except inside double quotes. An unclosed quote runs to the end, which
    /// is what a person half way through typing a phrase means by it.
    private static func tokens(in query: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false

        func flush(wasQuoted: Bool) {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            // A token with no letter and no digit in it is punctuation the user typed around a
            // word, and on its own it matches nothing FTS5 has tokenised.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            tokens.append(Token(text: text, wasQuoted: wasQuoted))
        }

        for character in query {
            if character == "\"" {
                flush(wasQuoted: inQuotes)
                inQuotes.toggle()
            } else if character.isWhitespace, !inQuotes {
                flush(wasQuoted: false)
            } else {
                current.append(character)
            }
        }
        flush(wasQuoted: inQuotes)
        return tokens
    }

    /// Reads FTS5's marked snippet back into segments.
    ///
    /// A mark with nothing between it is dropped rather than kept as an empty segment, so a view
    /// drawing the segments cannot end up with a highlight of no width sitting in the middle of a
    /// word.
    public static func snippet(from marked: String) -> TranscriptSnippet {
        var segments: [TranscriptSnippet.Segment] = []
        var current = ""
        var isMatch = false

        func flush() {
            guard !current.isEmpty else { return }
            // Consecutive runs of the same kind become one segment: FTS5 marks each matched term
            // separately, so "the WAL file" searched for "wal file" arrives as two marked words
            // with a space between them and reads better as one.
            if var last = segments.last, last.isMatch == isMatch {
                last.text += current
                segments[segments.count - 1] = last
            } else {
                segments.append(TranscriptSnippet.Segment(text: current, isMatch: isMatch))
            }
            current = ""
        }

        for character in marked {
            if String(character) == openMark {
                flush()
                isMatch = true
            } else if String(character) == closeMark {
                flush()
                isMatch = false
            } else {
                current.append(character)
            }
        }
        flush()

        return TranscriptSnippet(segments: segments)
    }

    /// Folds ranked matches into one row per workspace.
    ///
    /// The order of the workspaces is the order of their best match, which is the order the rows
    /// arrived in, so this is a stable fold rather than a sort. Ranking a workspace by anything
    /// else (its recency, its number of matches) was tried and it moved the obviously right answer
    /// down the list: a single exact sentence beats a workspace that says the word in passing
    /// forty times, and bm25 already knows that.
    public static func group(
        _ matches: [TranscriptMatch],
        totals: [WorkspaceID: Int] = [:],
        perWorkspace: Int = matchesPerWorkspace
    ) -> [TranscriptWorkspaceMatches] {
        var order: [WorkspaceID] = []
        var byWorkspace: [WorkspaceID: [TranscriptMatch]] = [:]

        for match in matches {
            if byWorkspace[match.workspaceID] == nil { order.append(match.workspaceID) }
            byWorkspace[match.workspaceID, default: []].append(match)
        }

        return order.map { workspaceID in
            let all = byWorkspace[workspaceID] ?? []
            return TranscriptWorkspaceMatches(
                workspaceID: workspaceID,
                matches: Array(all.prefix(perWorkspace)),
                // The total comes from a count over the whole index rather than from what was
                // fetched, because the candidate list is truncated and a workspace at the bottom
                // of it would otherwise claim to have one match when it has ninety.
                total: max(totals[workspaceID] ?? all.count, all.count)
            )
        }
    }

    /// How a row of the transcript is described in a result, so a reader can tell a thing they
    /// said from a thing the agent found.
    public static func label(for kind: MessageKind) -> String {
        switch kind {
        case .user: "You"
        case .assistantText: "Agent"
        case .thinking: "Thinking"
        case .toolUse: "Tool call"
        case .toolResult: "Tool output"
        case .error: "Error"
        // One word for all four crew events, because a search result cannot say which of them a
        // row is without decoding it, and every one of them is a message the owner did not type.
        case .crew: "Message"
        case .result, .system, .notice, .permissionAsk: "Transcript"
        }
    }
}
