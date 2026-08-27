import Foundation

/// What a workspace opens on the first time you see it, and which of the three things the create
/// sheet is asking for.
///
/// Deliberately a starting layout rather than a mode of the workspace. A terminal workspace, a
/// browser workspace and a chat workspace are the same thing: same worktree, same setup script,
/// same inspector, same review and pull request flow. The only difference is which tab has focus
/// when the workspace opens, and any of them can gain the other kinds of tab afterwards from the
/// `+` menu.
///
/// That is the whole reason this is one enum and a single stored hint rather than a mode: there is
/// no second set of rules to keep consistent, and nothing a workspace can be locked out of.
///
/// It is a mode of the SHEET, though, and that is new. The sheet used to offer both routes at once
/// as two buttons beside each other, which meant a person could write five hundred words and then
/// press the button that never sends them anywhere. Choosing first is what removes that, because
/// the input the other route would have thrown away is not on screen in the first place. See
/// `WorkspaceStartPlan.carriedName` for what does survive the crossing.
///
/// In `BloomCore` rather than in the sheet, because everything below this line is a decision, and
/// a decision taken inside a `View` is a decision nothing can test.
public enum WorkspaceStartMode: String, CaseIterable, Identifiable, Sendable {
    /// Describe a task, and the agent starts on it. The branch name is derived from what you typed.
    case chat
    /// A shell in the worktree, and you run whatever you like in it. You name the branch yourself,
    /// because there is no task to derive one from.
    case terminal
    /// A browser tab beside the worktree, pointed wherever you take it. Named like a terminal one,
    /// and for the same reason: nothing is written that a name could be derived from.
    case browser

    public var id: String { rawValue }

    /// What the workspace's own controls call it, where the word sits beside other one word
    /// labels and the sentence around it has already said what is being chosen.
    public var label: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .browser: "Browser"
        }
    }

    /// What the create sheet's segmented control calls it.
    ///
    /// Chat is the only one longer than `label`, and it is the only one with anything extra to
    /// say: what separates the three is whether an agent runs, so that segment names the agent and
    /// the other two name the tab you land on.
    ///
    /// "Just a terminal" was here while there were two segments, where "just" could only be read
    /// against the one beside it. A third segment leaves it comparing itself to two things at
    /// once, and a control offering three starting points reads as a list, which a disclaimer is
    /// not a member of. The tab is called Terminal everywhere else in the window; this says the
    /// same word.
    public var sheetLabel: String {
        switch self {
        case .chat: "Chat with an agent"
        case .terminal: "Terminal"
        case .browser: "Browser"
        }
    }

    /// Whether an agent runs here. The one question the rest of the sheet is downstream of: the
    /// model, the reasoning effort, the output style, the permission mode and the paperclip all
    /// exist to qualify a turn, and a terminal or browser workspace has no turn to qualify.
    public var runsAnAgent: Bool { self == .chat }

    /// The pane this mode opens the workspace on.
    ///
    /// The mapping is here rather than in the centre column because it is the only place the two
    /// lists meet, and because a fourth kind added to either one has to be answered for rather
    /// than fall through a `default` in a view. See `NewPane`, which is what makes the pane.
    public var pane: PaneKind {
        switch self {
        case .chat: .chat
        case .terminal: .terminal
        case .browser: .browser
        }
    }

    /// What opens once the worktree is there, as the second half of the sentence
    /// `WorkspaceStartPlan.startNote` builds.
    ///
    /// Here rather than inside that sentence because it is the one part of it that differs by
    /// mode, and three near-identical sentences kept in three places is how two of them come to
    /// disagree with the third.
    public var openingSentence: String {
        switch self {
        case .chat: "the agent starts on it"
        case .terminal: "a shell opens in the worktree"
        case .browser: "a browser opens beside it"
        }
    }

    // MARK: - What the sheet opens on

    /// Where the last choice is kept.
    ///
    /// Global, not per project, on purpose. Which of these you reach for is a fact about how you
    /// work rather than about a repository: somebody who lives in a shell lives in one in every
    /// checkout, and somebody who drives agents does that everywhere too. Keyed per project it
    /// would also be wrong most often exactly when it is least expected, on the first creation in
    /// a new project, which is the moment a person is least inclined to go looking for a control.
    ///
    /// It is the answer to this direction's own strongest objection. Choosing first costs a click
    /// before the first word, and nineteen creations out of twenty are chats, so a control that
    /// always opened on chat would be a control nineteen people read past and one person fights.
    /// Remembered, it is right by default for whoever you actually are, and the twentieth person
    /// pays the click once.
    public static let rememberedKey = "create.mode"

    /// Which mode the sheet opens on, given whatever is in the defaults.
    ///
    /// Chat for a fresh install, for the reason above: it is what nineteen in twenty want, and it
    /// is the only one of the three that a person who has not decided yet can back out of by
    /// simply typing. An unreadable or removed value is a fresh install as far as this is
    /// concerned.
    public static func remembered(raw: String?) -> WorkspaceStartMode {
        raw.flatMap(WorkspaceStartMode.init(rawValue:)) ?? .chat
    }

    // MARK: - Which tab a new workspace opens on

    /// Written at creation and read when the workspace is first opened.
    ///
    /// User defaults rather than a column: this is a hint about the opening layout, it stops
    /// mattering the moment the user touches a tab, and putting it in the database would mean a
    /// migration for something that is allowed to be forgotten.
    ///
    /// The mode's raw value rather than a flag. It was `opensOnTerminal`, a `Bool`, which could
    /// only ask for the one tab there was a case for; a third mode turns "does it open on a
    /// terminal" into "which of them does it open on", and a second boolean beside the first would
    /// have made two keys that can both be true.
    public static func defaultsKey(workspaceID: WorkspaceID) -> String {
        "workspace.opensOn.\(workspaceID)"
    }

    /// The key the boolean flag was written under, still read once and cleared.
    ///
    /// A workspace created by the previous build and not opened before the update lands would
    /// otherwise open on a chat it never asked for, and its `true` would sit in the defaults for
    /// good with nothing left that reads it. One release's worth of politeness, and the clearing
    /// is what makes it self-limiting.
    static func legacyTerminalKey(workspaceID: WorkspaceID) -> String {
        "workspace.opensOnTerminal.\(workspaceID)"
    }

    /// - Parameter defaults: injected for the same reason `remembered(raw:)` takes a raw string
    ///   rather than reading one. Eight other core types already take this, and a test that wrote
    ///   to `.standard` would be writing into the owner's own `be.spatie.bloom` domain, which is
    ///   the one thing `CLAUDE.md` says never to touch. So a decision worth pinning was untestable
    ///   and testing it would have been actively dangerous.
    ///
    /// Chat writes nothing. It is the ordinary case and the centre column's own default, so a key
    /// for it would be a key per workspace ever created, forever, saying what would have happened
    /// anyway.
    public static func record(
        _ mode: WorkspaceStartMode, workspaceID: WorkspaceID, defaults: UserDefaults = .standard
    ) {
        guard mode != .chat else { return }
        defaults.set(mode.rawValue, forKey: defaultsKey(workspaceID: workspaceID))
    }

    /// Which tab this workspace was promised, once, for one that has not been opened yet. Reading
    /// it clears it, so re-selecting the workspace later does not keep forcing a tab in front of
    /// whatever the user has since arranged.
    ///
    /// Nil is "nothing to do", which covers a chat start, a workspace nobody recorded anything
    /// for, and a value written by a version that knows a mode this one does not. The key is
    /// cleared in that last case too: a hint nothing here can honour is a hint that will never be
    /// honoured.
    public static func consumeOpeningTab(
        workspaceID: WorkspaceID, defaults: UserDefaults = .standard
    ) -> WorkspaceStartMode? {
        let key = defaultsKey(workspaceID: workspaceID)
        if let raw = defaults.string(forKey: key) {
            defaults.removeObject(forKey: key)
            let recorded = WorkspaceStartMode(rawValue: raw)
            return recorded == .chat ? nil : recorded
        }
        let legacy = legacyTerminalKey(workspaceID: workspaceID)
        guard defaults.bool(forKey: legacy) else { return nil }
        defaults.removeObject(forKey: legacy)
        return .terminal
    }
}
