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

    /// What this record is made of, in the one line a tooltip has.
    ///
    /// **It was three columns and a share bar on a screen of its own, and it is a tooltip because
    /// Home's row has no room for any of it.** That row is two lines and three columns of fixed
    /// width, and the widths are fixed precisely so a mark, a count and an age line up down the
    /// list; a fourth column for a message count, or a bar under every row, costs the alignment
    /// that makes the list readable to buy a number nobody orders by. The size earns its column
    /// because it is the number the list can be ordered by and the number the Archived chip now
    /// exists to answer.
    ///
    /// The branch standing is here rather than on the row for a different reason. It is the fact
    /// that decides whether this record is the last thing left of the work, which makes it worth
    /// saying, and it is already said in full by `ArchiveDeletion.branchStanding` at the only
    /// moment anyone can act on it. On the row it would be a fourth thing on a two-line row, on
    /// every row, saying nothing on most of them.
    public var contents: String {
        var parts = [ArchiveDeletion.bytes(totalBytes)]
        if messageCount > 0 {
            parts.append(
                "\(ArchiveDeletion.count(messageCount, "transcript message")) in "
                + "\(ArchiveDeletion.count(sessionCount, "chat"))"
            )
        }
        if branchIsLocal == false { parts.append("branch not on this Mac") }
        return parts.joined(separator: " \u{00B7} ")
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

/// The archived workspaces and what they hold between them.
///
/// **It used to order them and reconcile a multi-selection with a right-clicked row, and neither
/// is anybody's job any more.** Both existed for a Settings pane that listed the archived
/// workspaces a second time with a Largest/Oldest switch, a tick box per row and a Delete button
/// over the selection. That pane has gone into Home, which was already drawing the same rows:
/// Home orders its own list (`HomeOrder`, because "oldest first" is not one of the orders a
/// date-grouped list can offer), and Home is single-selection, so a delete is always the one row
/// that was clicked and there is nothing to reconcile it with.
///
/// If Home ever grows a multi-selection, the rule that went is worth reading before writing
/// another: `ArchiveCleanup.target` in the history, and the destructive bug in its doc comment,
/// where a confirmation counted one workspace over a selection of three.
public struct ArchiveCleanup: Sendable, Hashable {
    public let footprints: [ArchivedWorkspaceFootprint]

    public init(footprints: [ArchivedWorkspaceFootprint]) {
        self.footprints = footprints
    }

    public var totalBytes: Int {
        footprints.reduce(0) { $0 + $1.totalBytes }
    }

    public var isEmpty: Bool { footprints.isEmpty }
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

    /// Why the list's total and the file's size are two different numbers, said on the control
    /// that closes the gap.
    ///
    /// **Deleting rows does not shrink the file.** SQLite puts the pages on a free list and
    /// reuses them, which is right and is also the reason a delete of half a gigabyte changes
    /// nothing in Finder. It has to be said somewhere, and where it used to be said was a
    /// paragraph across the foot of a pane of its own. Home's foot is one line, so it is the
    /// tooltip on the button it is about, standing next to the number it explains.
    public var compactionHelp: String {
        """
        \(ArchiveDeletion.bytes(freeBytes)) inside the database is space nothing is using. \
        Deleting frees pages inside the file; compacting rewrites the file and hands them back to \
        the disk, which takes a while and stops everything else while it runs.
        """
    }
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

/// What came of destroying a set of archived records.
///
/// It used to be an `Int` that the one call site discarded, over a store call wrapped in `try?`,
/// so a refused write and an empty selection were the same value. On a refusal the selection
/// cleared, the list reloaded, every row was still there, and the reader was told nothing at all.
/// A count is not an outcome: the two questions are "how many went" and "did it work".
public enum ArchiveDeletionOutcome: Sendable, Hashable {
    case deleted(Int)
    case refused(complaint: String)

    /// What to say, or nothing when there is nothing worth saying.
    ///
    /// A successful delete says nothing: the rows leave the list, which is the whole report. Only
    /// the refusal has a sentence, and it follows `WorkspaceTrouble`'s rule of naming what is
    /// wrong, what is safe, and whether trying again helps.
    ///
    /// In paragraphs for the reason `WorkspaceTrouble.sentence` is: this is read in a dialogue at
    /// the moment something went wrong, and one block of it is a wall somebody skips on the way
    /// to the button. The middle paragraph is the one that says nothing was destroyed.
    public var sentence: String? {
        switch self {
        case .deleted: return nil
        case let .refused(complaint):
            return """
                Bloom could not delete those archived workspaces, so they are all still here \
                and nothing has been freed.

                No worktree and no branch was involved: this is the database refusing to write, \
                and it will refuse the next attempt the same way.

                Quit Bloom and open it again, and if it happens a second time the database itself \
                needs looking at.

                The database said: \(complaint)
                """
        }
    }

    /// Whether the rows this was asked about are gone, which is what decides whether a selection
    /// may be cleared.
    public var didDelete: Bool {
        if case let .deleted(count) = self { return count > 0 }
        return false
    }
}

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
    ///
    /// The apostrophe is the typographic one, and that is the whole of a small fix. This dialogue
    /// puts a quoted workspace name in its title and a possessive in its body, and it was the one
    /// place in the app where a curly pair and a straight tick were read in the same breath. The
    /// quotation marks were already typographic and deliberately so (see `HomeView`, which says
    /// why), so the mark that had to move was this one.
    public var summary: String {
        let subject = footprints.count == 1 ? "This workspace" : "These workspaces"
        let pronoun = footprints.count == 1 ? "its" : "their"
        return """
        \(subject) already lost \(pronoun) worktree when \(footprints.count == 1 ? "it was" : "they were") \
        archived, and that could be undone as long as the branch survived. This cannot. It removes \
        the record from Bloom\u{2019}s database, and there is nothing anywhere else that holds a copy.
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
    ///
    /// Public because it was not, and three views wrote it again rather than reach for it. Two of
    /// the three dropped `.formatted()` while they were at it, so the same machine read "1000
    /// workspaces" on Home and "1,000 chats" here.
    /// - Parameter plural: for the nouns an `s` does not pluralise. "match" is the one that
    ///   forced it: Home's transcript heading counts matches, and "1 matchs" is the sort of thing
    ///   a reader stops on.
    public static func count(_ value: Int, _ noun: String, plural: String? = nil) -> String {
        let word = value == 1 ? noun : (plural ?? noun + "s")
        return "\(value.formatted()) \(word)"
    }

    /// One formatter for every size in this feature, so the list, the summary and the confirmation
    /// can never disagree about what a megabyte is.
    public static func bytes(_ value: Int) -> String {
        value.formatted(.byteCount(style: .file))
    }
}
