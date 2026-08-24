import Foundation

/// What a workspace opens on the first time you see it, and which of the two things the create
/// sheet is asking for.
///
/// Deliberately a starting layout rather than a mode of the workspace. A terminal workspace and a
/// chat workspace are the same thing: same worktree, same setup script, same inspector, same
/// review and pull request flow. The only difference is which tab has focus when the workspace
/// opens, and either kind can gain the other kind of tab afterwards from the `+` menu.
///
/// That is the whole reason this is one enum and a single stored flag rather than a mode: there is
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

    public var id: String { rawValue }

    /// What the workspace's own controls call it, where the word sits beside other one word
    /// labels and the sentence around it has already said what is being chosen.
    public var label: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        }
    }

    /// What the create sheet's segmented control calls it.
    ///
    /// Longer than `label`, because these two words are the only thing on the sheet saying what
    /// the difference is. "Chat" and "Terminal" side by side name two tabs; "Chat with an agent"
    /// and "Just a terminal" name two outcomes, and the second one is the sentence the button it
    /// replaces had already earned.
    public var sheetLabel: String {
        switch self {
        case .chat: "Chat with an agent"
        case .terminal: "Just a terminal"
        }
    }

    /// Whether an agent runs here. The one question the rest of the sheet is downstream of: the
    /// model, the reasoning effort, the output style, the permission mode and the paperclip all
    /// exist to qualify a turn, and a terminal workspace has no turn to qualify.
    public var runsAnAgent: Bool { self == .chat }

    // MARK: - What the sheet opens on

    /// Where the last choice is kept.
    ///
    /// Global, not per project, and beside `create.more` on purpose. Which of the two you reach
    /// for is a fact about how you work rather than about a repository: somebody who lives in a
    /// shell lives in one in every checkout, and somebody who drives agents does that everywhere
    /// too. Keyed per project it would also be wrong most often exactly when it is least expected,
    /// on the first creation in a new project, which is the moment a person is least inclined to
    /// go looking for a control.
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
    /// is the only one of the two that a person who has not decided yet can back out of by simply
    /// typing. An unreadable or removed value is a fresh install as far as this is concerned.
    public static func remembered(raw: String?) -> WorkspaceStartMode {
        raw.flatMap(WorkspaceStartMode.init(rawValue:)) ?? .chat
    }

    // MARK: - Which tab a new workspace opens on

    /// Written at creation and read when the workspace is first opened.
    ///
    /// User defaults rather than a column: this is a hint about the opening layout, it stops
    /// mattering the moment the user touches a tab, and putting it in the database would mean a
    /// migration for something that is allowed to be forgotten.
    public static func defaultsKey(workspaceID: WorkspaceID) -> String {
        "workspace.opensOnTerminal.\(workspaceID)"
    }

    /// - Parameter defaults: injected for the same reason `remembered(raw:)` takes a raw string
    ///   rather than reading one. Eight other core types already take this, and a test that wrote
    ///   to `.standard` would be writing into the owner's own `be.spatie.bloom` domain, which is
    ///   the one thing `CLAUDE.md` says never to touch. So a decision worth pinning was untestable
    ///   and testing it would have been actively dangerous.
    public static func record(
        _ mode: WorkspaceStartMode, workspaceID: WorkspaceID, defaults: UserDefaults = .standard
    ) {
        guard mode == .terminal else { return }
        defaults.set(true, forKey: defaultsKey(workspaceID: workspaceID))
    }

    /// True once, for a workspace created as a terminal one that has not been opened yet. Reading
    /// it clears it, so re-selecting the workspace later does not keep forcing a terminal tab in
    /// front of whatever the user has since arranged.
    public static func consumeOpensOnTerminal(
        workspaceID: WorkspaceID, defaults: UserDefaults = .standard
    ) -> Bool {
        let key = defaultsKey(workspaceID: workspaceID)
        guard defaults.bool(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        return true
    }
}
