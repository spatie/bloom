import Foundation

/// What one archived workspace still occupies, and what deleting it would destroy.
///
/// Archiving removes the worktree and, if the project asks for it, the branch. It removes nothing
/// from the database at all: `Workspace.archive()` writes two columns and every row that ever
/// hung off the workspace is still there. So an archived workspace costs no disk outside
/// `bloom.sqlite` and, inside it, costs everything it ever did.
///
/// **The bytes here are measured, not estimated, and they are deliberately an undercount.** The
/// numbers come from `LENGTH()` over the columns that actually hold content, dominated by
/// `messages.payload`, which is the raw JSON line the agent CLI emitted for every turn, tool call
/// and result. Three things deleting also frees are not in the total: the FTS rows in
/// `message_search`, which hold a second copy of the derived prose and go with the messages
/// through the delete trigger; SQLite's own per-row and per-page overhead; and the indexes. Every
/// one of them makes the real saving larger than the figure shown, which is the only direction an
/// error here is allowed to point. A screen that promises 400 MB and returns 3 MB is worse than a
/// screen with no number on it.
public struct ArchivedWorkspaceFootprint: Sendable, Identifiable, Hashable {
    public let workspace: Workspace
    /// The project the workspace belonged to, for a list that spans several of them.
    public let repoName: String
    /// Chats, which is what a session is to a reader.
    public let sessionCount: Int
    /// Transcript rows: every user turn, agent turn, tool call and tool result.
    public let messageCount: Int
    /// `SUM(LENGTH(messages.payload))`. On any workspace an agent actually worked in this is
    /// almost the whole figure.
    public let transcriptBytes: Int
    /// The rest of the content with a foreign key to this workspace: review comments and their
    /// captured context, the notes pane, the setup log, and the recorded permission requests.
    public let otherBytes: Int
    /// Inline review comments, which are written by hand and are the one thing here a person may
    /// have typed themselves.
    public let reviewCommentCount: Int
    /// Whether the notes pane holds anything.
    public let hasNote: Bool
    /// Whether the branch this workspace was on is still on this Mac, or nil while nobody has
    /// looked yet.
    ///
    /// A `var` filled in after the row is measured, because the answer comes from git and `Store`
    /// runs no subprocess. Nil is a real third state and the wording depends on it: "the branch is
    /// gone" is a promise, and a screen has no business making it out of a question it never
    /// asked. `RestoreSource` is the fuller answer and needs a fetch per workspace, which is a
    /// network round trip a list of forty rows cannot afford; this is the local half of it, one
    /// `git branch` per project.
    public var branchIsLocal: Bool?

    public var id: WorkspaceID { workspace.id }

    /// What deleting this row would stop the database from holding.
    public var totalBytes: Int { transcriptBytes + otherBytes }

    /// When it was archived, or when it was last touched for a row archived before the column
    /// existed. Never nil, because a list sorted by age cannot have a hole in it.
    public var archivedAt: Date {
        workspace.archivedAt ?? workspace.lastActivityAt
    }

    public init(
        workspace: Workspace,
        repoName: String,
        sessionCount: Int,
        messageCount: Int,
        transcriptBytes: Int,
        otherBytes: Int,
        reviewCommentCount: Int,
        hasNote: Bool,
        branchIsLocal: Bool? = nil
    ) {
        self.workspace = workspace
        self.repoName = repoName
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.transcriptBytes = transcriptBytes
        self.otherBytes = otherBytes
        self.reviewCommentCount = reviewCommentCount
        self.hasNote = hasNote
        self.branchIsLocal = branchIsLocal
    }
}

/// How the list is ordered, as a value rather than as whichever sort the view last ran.
public enum ArchiveCleanupOrder: String, Sendable, CaseIterable, Hashable {
    /// What the screen is for: the rows holding the most come first.
    case largest
    /// What the owner asked for in words: the ones archived longest ago come first.
    case oldest

    public var label: String {
        switch self {
        case .largest: "Largest"
        case .oldest: "Oldest"
        }
    }
}

/// The archived workspaces, ordered, totalled, and able to say what deleting a selection destroys.
///
/// Pure, and it holds every decision this screen makes apart from where the pixels go. The view
/// that draws it owns no rule about ordering, no arithmetic and no sentence.
public struct ArchiveCleanup: Sendable, Hashable {
    public let footprints: [ArchivedWorkspaceFootprint]

    public init(footprints: [ArchivedWorkspaceFootprint]) {
        self.footprints = footprints
    }

    /// The rows in the order asked for.
    ///
    /// Both orders break ties the same way, on the identifier, because a list that reshuffles
    /// equal rows between two refreshes is a list somebody clicks the wrong row in. Every
    /// workspace archived in the same second by the same script is such a tie.
    public func ordered(by order: ArchiveCleanupOrder) -> [ArchivedWorkspaceFootprint] {
        footprints.sorted { first, second in
            switch order {
            case .largest:
                if first.totalBytes != second.totalBytes { return first.totalBytes > second.totalBytes }
            case .oldest:
                if first.archivedAt != second.archivedAt { return first.archivedAt < second.archivedAt }
            }
            return first.id.rawValue < second.id.rawValue
        }
    }

    public var totalBytes: Int {
        footprints.reduce(0) { $0 + $1.totalBytes }
    }

    public var messageCount: Int {
        footprints.reduce(0) { $0 + $1.messageCount }
    }

    public var isEmpty: Bool { footprints.isEmpty }

    /// The rows for a selection, in the order they were shown, so the confirmation lists them the
    /// way the list did.
    public func selected(
        _ ids: Set<WorkspaceID>, order: ArchiveCleanupOrder
    ) -> [ArchivedWorkspaceFootprint] {
        ordered(by: order).filter { ids.contains($0.id) }
    }
}

/// The size of the database file, in the two numbers that matter after a delete.
///
/// Pages rather than bytes on disk, because in WAL mode the database is three files and only one
/// of them is permanent. See `Store.compactDatabase` for why the free pages are shown at all.
public struct DatabaseSize: Sendable, Hashable {
    public let pageSize: Int
    public let pageCount: Int
    public let freePageCount: Int

    public init(pageSize: Int, pageCount: Int, freePageCount: Int) {
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.freePageCount = freePageCount
    }

    public var totalBytes: Int { pageSize * pageCount }
    /// Space inside the file that nothing is using and that only a compaction gives back.
    public var freeBytes: Int { pageSize * freePageCount }
    public var usedBytes: Int { totalBytes - freeBytes }

    /// Whether compacting is worth offering.
    ///
    /// A database always carries some free pages: SQLite reuses them, which is the point. Below
    /// this the offer is noise, and taking it would cost more time than the space is worth. Eight
    /// megabytes is roughly one large transcript, which is the smallest saving a person would
    /// notice in Finder.
    public var isWorthCompacting: Bool { freeBytes >= 8 * 1_000_000 }
}

/// What deleting a set of archived workspaces would destroy, in the words the confirmation uses.
///
/// The register is `WorkspaceSafetyReport.losses`: name what goes, counted and pluralised, rather
/// than asking whether the reader is sure. The difference from that type is which way the danger
/// runs. Archiving is reversible, and its confirmation is about the working copy, the files and
/// commits git has no other copy of. Everything archiving could take is already gone by the time a
/// workspace appears here. What is left is the record: the conversation, what the agent was asked,
/// what it did, and the review someone wrote on it. `WorkspaceRestore` can bring a workspace back
/// from a branch and can never bring any of that back, so this confirmation says so plainly.
public struct ArchiveDeletion: Sendable, Hashable {
    public let footprints: [ArchivedWorkspaceFootprint]

    public init(_ footprints: [ArchivedWorkspaceFootprint]) {
        self.footprints = footprints
    }

    public var isEmpty: Bool { footprints.isEmpty }

    public var totalBytes: Int { footprints.reduce(0) { $0 + $1.totalBytes } }

    /// Named when there is one, counted when there are several. A title carrying forty names is a
    /// title nobody reads to the end of.
    public var title: String {
        if let only = footprints.first, footprints.count == 1 {
            return "Delete everything Bloom kept about \u{201C}\(only.workspace.name)\u{201D}?"
        }
        return "Delete everything Bloom kept about \(Self.count(footprints.count, "archived workspace"))?"
    }

    /// The sentence above the list: what state this leaves things in.
    public var summary: String {
        let subject = footprints.count == 1 ? "This workspace" : "These workspaces"
        let pronoun = footprints.count == 1 ? "its" : "their"
        return """
        \(subject) already lost \(pronoun) worktree when \(footprints.count == 1 ? "it was" : "they were") \
        archived, and that could be undone as long as the branch survived. This cannot. It removes \
        the record from Bloom's database, and there is nothing anywhere else that holds a copy.
        """
    }

    /// One line per thing that would be destroyed, counted and pluralised, in the order a reader
    /// would weigh them: the conversation first, because it is the largest and the only one that
    /// cannot be reconstructed from anything.
    public var losses: [String] {
        var losses: [String] = []

        let messages = footprints.reduce(0) { $0 + $1.messageCount }
        let sessions = footprints.reduce(0) { $0 + $1.sessionCount }
        if messages > 0 {
            losses.append(
                "\(Self.count(messages, "transcript message")) across "
                + "\(Self.count(sessions, "chat")), holding \(Self.bytes(totalBytes))"
            )
        } else if totalBytes > 0 {
            losses.append("\(Self.bytes(totalBytes)) of recorded work")
        }

        let comments = footprints.reduce(0) { $0 + $1.reviewCommentCount }
        if comments > 0 {
            losses.append("\(Self.count(comments, "review comment")) written by hand")
        }

        let notes = footprints.filter(\.hasNote).count
        if notes > 0 {
            losses.append(notes == 1 ? "a workspace note" : "\(notes) workspace notes")
        }

        return losses
    }

    /// What survives, which is the half a confirmation usually forgets and the half that decides
    /// whether this is frightening or routine.
    ///
    /// A branch still on this Mac means the commits are not in question at all: `WorkspaceRestore`
    /// could not have brought the conversation back either way, so what this delete costs is the
    /// conversation and nothing else. A branch that is not here might still be on a remote, and
    /// this screen has not asked, so it says exactly that rather than declaring the work gone.
    public var branchStanding: String? {
        let known = footprints.compactMap(\.branchIsLocal)
        guard known.count == footprints.count, !footprints.isEmpty else { return nil }

        if known.allSatisfy({ $0 }) {
            let branches = footprints.count == 1
                ? "The branch \(footprints[0].workspace.branch) is"
                : "All \(footprints.count) branches are"
            return "\(branches) still on this Mac, so no commit is affected. What goes is the record of the work, not the work."
        }
        if known.allSatisfy({ !$0 }) {
            let subject = footprints.count == 1
                ? "The branch \(footprints[0].workspace.branch) is"
                : "None of these branches are"
            return "\(subject) not on this Mac. If no remote still carries \(footprints.count == 1 ? "it" : "them"), this record is the last thing left of the work."
        }
        let gone = known.filter { !$0 }.count
        return """
        \(gone) of these \(footprints.count) branches \(gone == 1 ? "is" : "are") no longer on this Mac. \
        If no remote still carries \(gone == 1 ? "it" : "them"), \(gone == 1 ? "that record is" : "those records are") \
        the last thing left of that work.
        """
    }

    /// Deliberately not "Delete", and deliberately not "Are you sure". It names the one property
    /// that separates this from every other destructive button in Bloom.
    public var confirmLabel: String { "Delete permanently" }

    public var cancelLabel: String {
        footprints.count == 1 ? "Keep the record" : "Keep the records"
    }

    /// The whole message body, assembled the way `RootView` assembles the archive confirmation, so
    /// the two dialogues read as the same app talking.
    public var message: String {
        var body = summary
        if !losses.isEmpty {
            body += "\n\nThis deletes:\n" + losses.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }
        if let branchStanding {
            body += "\n\n" + branchStanding
        }
        return body
    }

    /// "1 chat", "3 chats". The same helper `WorkspaceSafetyReport` keeps, for the same reason:
    /// this is read at the moment somebody decides whether to destroy something, which is the
    /// worst place in the app to make them translate "message(s)".
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    /// One formatter for every size in this feature, so the list, the summary and the confirmation
    /// can never disagree about what a megabyte is.
    public static func bytes(_ value: Int) -> String {
        value.formatted(.byteCount(style: .file))
    }
}
