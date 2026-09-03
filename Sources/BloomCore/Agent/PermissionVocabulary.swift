import Foundation

/// The permission modes in the words of whichever CLI is about to run them.
///
/// **A user opened the Codex app beside Bloom and could not match up the two menus.** Bloom's
/// picker said "Ask, Accept edits, Full access" over a Codex chat, which is Claude Code's
/// vocabulary printed over another product's settings, and the row he wanted, the one the Codex
/// app calls "Approve for me", was missing on top of that. Somebody who has read one product's
/// documentation should recognise the words in front of him, so the labels and the sentences below
/// are the vendors' own rather than Bloom's summaries of them.
///
/// Where they come from, so the next person can check them rather than trust them. Codex's four
/// presets, their ids and their sentences are in the `codex` binary at 0.149.1: `read-only`
/// "Read Only", `workspace` "Ask for approval", `auto` "Approve for me", `full-access`
/// "Full Access". Claude Code's are in its own binary at 2.1.246, where `--permission-mode` takes
/// `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk` and `plan`, and `auto` is
/// documented there as "Use a model classifier to approve/deny permission prompts".
///
/// Sentence case, not the vendors' title case ("Read Only", "Full Access"). These are menu items
/// on a Mac and everything else in the same menu is sentence case; matching the vendor's
/// capitalisation letter for letter would buy recognition of one word at the cost of a menu that
/// looks assembled from two apps.
public extension PermissionMode {
    /// What this row is called for a chat running on `kind`.
    func label(on kind: AgentKind) -> String {
        switch kind {
        case .codex: codexLabel
        case .claudeCode, .cursor, .openCode: claudeCodeLabel
        }
    }

    /// One line saying what picking this row would do, in the same vocabulary.
    ///
    /// It exists because "Only ask for actions detected as potentially unsafe" is the sentence
    /// that made the mode legible to the person who reported this, and a label on its own is not.
    ///
    /// **It is printed under the row it belongs to, on every row, not under the menu.** It was a
    /// single footnote describing the selected mode, because an `NSMenu` row is one line with no
    /// space beneath it, and the owner read that menu and said "I cannot see what the option does
    /// before picking it": the one thing a picker of permissions has to answer was the one thing
    /// only answered after the choice. The picker is a popover of two line rows now, so the
    /// limitation went rather than the workaround. See `ComposerOptionList`.
    func summary(on kind: AgentKind) -> String {
        switch kind {
        case .codex: codexSummary
        case .claudeCode, .cursor, .openCode: claudeCodeSummary
        }
    }

    /// Where a chat's mode lands when it moves to a backend that has no row for it.
    ///
    /// Only two of the five modes ever move. `autoReview` off Codex is exact rather than
    /// approximate: Claude Code's Auto is the mode Codex calls Approve for me, so nothing is lost
    /// in the translation. `plan` on Codex is the lossy one, and it is lossy because Codex has
    /// nothing that means "work it out and touch nothing".
    ///
    /// **Plan falls to Read only, and it used to fall to Ask for approval.** That was the widest
    /// of the two and it was the wrong way to be wrong: Plan is the strictest row in the picker,
    /// Codex's Ask for approval can write the worktree and run commands without being asked, and
    /// a chat moved from one backend to the other would have been quietly granted that. Read only
    /// is the Codex preset that keeps Plan's promise, which is that nothing changes until you say
    /// so. `CodexRunner.sandboxMode` had already reached the same answer from the other end and
    /// says it in one line: "Read only and Plan both mean do not write without telling me."
    func nearest(on kind: AgentKind) -> PermissionMode {
        switch self {
        case .autoReview: kind == .codex ? self : .auto
        case .plan: kind == .codex ? .auto : self
        case .auto, .acceptEdits, .bypassPermissions: self
        }
    }

    private var claudeCodeLabel: String {
        switch self {
        case .auto: "Auto"
        case .acceptEdits: "Accept edits"
        // Not offered on this side. Named all the same, because an exhaustive switch that returns
        // a name is cheaper to keep honest than one that returns an optional nobody reads.
        case .autoReview: "Auto"
        case .bypassPermissions: "Bypass permissions"
        case .plan: "Plan"
        }
    }

    private var claudeCodeSummary: String {
        switch self {
        // Claude Code's own account of the mode, cut to a line: "Auto mode lets Claude handle
        // permission prompts automatically. Claude checks each tool call for risky actions and
        // prompt injection before executing, runs the ones it assesses as lower-risk, and blocks
        // the rest."
        case .auto, .autoReview:
            "Claude checks each tool call for risk, runs the ones it judges lower risk, and blocks "
                + "the rest."
        case .acceptEdits: "File edits and common file commands are approved for you."
        case .bypassPermissions: "No further prompts. Everything runs."
        case .plan: "Research and propose changes without making them."
        }
    }

    private var codexLabel: String {
        switch self {
        case .auto: "Read only"
        case .acceptEdits: "Ask for approval"
        case .autoReview: "Approve for me"
        case .bypassPermissions: "Full access"
        // Not offered on this side either. It used to be named in the menu's footnote as a mode
        // Codex does not have, and the owner's verdict on that was that a picker should do the
        // right thing rather than explain itself: the row is absent, and so is the sentence.
        case .plan: "Plan"
        }
    }

    private var codexSummary: String {
        switch self {
        case .auto:
            "Codex can read files in the workspace. Approval is required to edit files or reach "
                + "the internet."
        case .acceptEdits:
            "Codex can read and edit files in the workspace, and run commands. Approval is "
                + "required to reach the internet or edit other files."
        case .autoReview: "Only ask for actions detected as potentially unsafe."
        case .bypassPermissions:
            "Codex can edit files outside the workspace and reach the internet without asking."
        case .plan: "Research and propose changes without making them."
        }
    }
}

/// One row of the permission picker: the mode, its name in the running backend's words, and the
/// sentence that says what picking it would do.
///
/// Assembled here rather than in the footer, because it is the pair of vendor strings above with
/// nothing added, and a view that reached for both separately is a view that can print one
/// backend's label over the other's sentence.
public struct PermissionModeChoice: Identifiable, Hashable, Sendable {
    public var mode: PermissionMode
    public var label: String
    public var summary: String

    public var id: PermissionMode { mode }

    public init(mode: PermissionMode, on kind: AgentKind) {
        self.mode = mode
        self.label = mode.label(on: kind)
        self.summary = mode.summary(on: kind)
    }
}
