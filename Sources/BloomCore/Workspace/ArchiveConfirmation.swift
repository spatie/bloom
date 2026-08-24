import Foundation

/// What the app knows about a workspace that a git process cannot.
///
/// Deliberately not fields on `WorkspaceSafetyReport`. That type is computed by running git, and
/// every field on it is something git answered; none of these is. An agent mid turn is a process
/// the app is holding a handle to, and the pull request's state came from `gh` minutes ago and is
/// cached above the core. Putting them on the report would mean a report that is wrong until
/// whoever built it remembers to correct it, which is the kind of half-filled safety check that
/// decides whether work gets destroyed.
public struct ArchiveHazards: Sendable, Hashable {
    /// An agent is mid turn in this workspace, right now.
    public var isAgentRunning: Bool
    /// GitHub says this branch's pull request was merged.
    ///
    /// Only ever `true` because GitHub actually said so, never inferred from its silence. The
    /// state it reflects is one-way: a pull request that has merged stays merged, so a cached
    /// answer can only ever be stale in the harmless direction, which is why the app is willing
    /// to read it from whichever surface asked last rather than blocking an archive on a network
    /// call.
    public var isPullRequestMerged: Bool
    /// Whether this archive will delete the branch as well as the worktree.
    public var isDeletingBranch: Bool

    public init(
        isAgentRunning: Bool = false,
        isPullRequestMerged: Bool = false,
        isDeletingBranch: Bool = false
    ) {
        self.isAgentRunning = isAgentRunning
        self.isPullRequestMerged = isPullRequestMerged
        self.isDeletingBranch = isDeletingBranch
    }

    /// The losses that are not git's to report.
    public var liveLosses: [String] {
        isAgentRunning
            ? ["the turn an agent is running in this workspace right now, which is not in git yet"]
            : []
    }
}

/// An archive the app refused to carry out, waiting on the user, in the words the dialogue uses.
///
/// It carries the report rather than a yes or no question, because "are you sure?" tells the user
/// nothing, and the whole point of stopping is that there is something specific to lose.
///
/// The labels and the message are computed here rather than in `RootView` because a decision taken
/// inside a view is a decision nothing can test, and this particular decision is the wording on
/// the one irreversible button in the app. `ArchiveDeletion` in `ArchivedWorkspaceFootprint.swift`
/// is the precedent: `confirmLabel`, `cancelLabel` and `message` on the value the dialogue is
/// built from.
public struct ArchiveRequest: Identifiable, Sendable {
    /// How loudly this particular archive deserves to be announced.
    ///
    /// Three levels rather than a bool, because the middle one is the whole point. It exists
    /// because the owner merged a pull request, pressed Archive, and was shown a red "Archive and
    /// lose that work" over thirteen ignored paths that were never in a commit and were never
    /// meant to be. One hazard list spoken in one voice is what did that, and a dialogue that
    /// cries wolf over a `.env` is a dialogue people learn to click through, on the one action in
    /// Bloom that cannot be undone.
    public enum Severity: Sendable, Hashable {
        /// Nothing is at stake. The dialogue is only here because the caller asked every time.
        case routine
        /// Something goes that nothing else would mention, and none of it is work git was
        /// holding: ignored files that differ from the main checkout.
        case worthMentioning
        /// Work that exists nowhere else, or an answer git could not give. Both keep the strong
        /// words and the red button.
        case destructive
    }

    public let id = UUID()
    public var workspace: Workspace
    public var report: WorkspaceSafetyReport
    public var deleteBranch: Bool?
    /// Set when git could not be asked at all, so the report is empty for want of an answer rather
    /// than because there is nothing at stake. Shown alongside the losses, never instead of them.
    public var problem: String?
    /// What the app knows about this workspace that git does not. See `ArchiveHazards`.
    public var hazards: ArchiveHazards

    public init(
        workspace: Workspace,
        report: WorkspaceSafetyReport,
        deleteBranch: Bool? = nil,
        problem: String? = nil,
        hazards: ArchiveHazards = ArchiveHazards()
    ) {
        self.workspace = workspace
        self.report = report
        self.deleteBranch = deleteBranch
        self.problem = problem
        self.hazards = hazards
    }

    /// Work that would be gone for good, in the order a reader weighs it.
    ///
    /// The live reasons come first. An agent mid turn is producing work that is not in git at all
    /// yet, so it is both the most valuable thing at stake and the one the report cannot see.
    public var losses: [String] {
        hazards.liveLosses + report.irreversibleLosses(
            deletingBranch: hazards.isDeletingBranch,
            isPullRequestMerged: hazards.isPullRequestMerged
        )
    }

    /// What goes with the worktree that is worth saying and is not worth a warning.
    public var notes: [String] {
        report.ignoredFileNotes
    }

    /// An unanswered check counts as destructive, and that is the load-bearing line here.
    ///
    /// When git could not be asked, the report is all zeroes and empty arrays, which reads
    /// exactly like a clean workspace. `Git.safetyReport` throws rather than returning that, and
    /// `AppModel` turns the throw into `problem`, so this is where the distinction has to be kept:
    /// an empty report with a problem beside it means "unknown", and unknown must never be shown
    /// as "nothing at stake".
    public var severity: Severity {
        if problem != nil { return .destructive }
        if !losses.isEmpty { return .destructive }
        return notes.isEmpty ? .routine : .worthMentioning
    }

    public var isDestructive: Bool { severity == .destructive }

    /// The confirming button's label, which only promises a loss when there is one.
    ///
    /// This dialogue is raised by the sidebar row's hover button as well, which asks every time
    /// precisely because it appears under the pointer unbidden. Telling somebody they are about to
    /// "lose that work" when the only thing going is a generated types folder is the fastest way
    /// to teach them that this dialogue exaggerates.
    public var confirmLabel: String {
        isDestructive ? "Archive and lose that work" : "Archive"
    }

    public var cancelLabel: String { "Keep the workspace" }

    /// What archiving does to this particular workspace, said as a list rather than as a question.
    ///
    /// A confirmation that only asks "are you sure?" is one people learn to click through, so this
    /// one always says what happens, and adds each list only when there is something on it.
    ///
    /// The worktree's path used to open this message and it took five wrapped lines of a narrow
    /// dialogue to say something the name above it had already said. What has to be read here is
    /// the lists, so the path is gone and the name identifies the workspace, which is what it does
    /// everywhere else in the app.
    public var message: String {
        var text = "\u{201C}\(workspace.name)\u{201D}\n\n"
        text += "The worktree is deleted and the branch is "
        text += hazards.isDeletingBranch ? "deleted too." : "kept."
        text += " The workspace moves to Archived."

        // Only where the stakes are already low. A merged pull request means the branch's code is
        // on the default branch, which is worth saying next to a list of ignored files and is not
        // worth saying next to uncommitted changes, because those were never in the pull request
        // and this sentence would read as reassurance about them.
        if hazards.isPullRequestMerged, !isDestructive {
            text += " Its pull request is merged, so the branch\u{2019}s work is already on the "
            text += "default branch."
        }

        let losses = losses
        if !losses.isEmpty {
            text += "\n\nThis would lose:\n"
            text += losses.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }

        let notes = notes
        if !notes.isEmpty {
            text += "\n\nAlso in the worktree, ignored by git and so in no commit by design:\n"
            text += notes.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }

        if let problem {
            text += "\n\n\(problem)"
        }
        return text
    }
}
