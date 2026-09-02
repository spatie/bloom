import Foundation

/// Which CLI a chat that has never been opened runs on, and the effort that survives arriving
/// there.
///
/// **Choosing a model is choosing a backend.** The composer has worked that way since Codex
/// arrived, and deliberately: there is no second picker, because a model id already names the CLI
/// that runs it and two controls saying the same thing are two controls to keep in step. See
/// `ComposerControls.agentKind`.
///
/// Settings, Models had no answer to that question at all. It offered Claude Code's four models,
/// wrote a name into `defaults.model`, and nothing anywhere mapped that name back to a backend, so
/// every new chat opened on Claude Code whatever the screen said. `AppModel.resolvedControls`
/// carried a comment saying so, and that comment now points here.
///
/// Three questions, in this order, and the order is the design:
///
/// 1. **Is this the model Settings recorded?** Then it is the backend Settings recorded beside it.
///    First, because it is the only question that needs nothing: Codex's model list is fetched, so
///    a rule that had to look an id up would answer "Claude Code" on a machine that is offline,
///    that has no Codex installed, or that has simply not had the fetch come back yet. A default
///    that changes backend while a list loads is worse than no default at all.
/// 2. **Does the model name its own backend?** Codex's fetched list is authoritative for its own
///    ids, and `ClaudeModelRank` recognises the four families for Claude Code's. This is the
///    question that decides a model which never came from Settings: a repository's
///    `models.default` outranks the app defaults, and a project pinning a GPT model means it.
/// 3. **Otherwise whatever is running**, which for a chat being opened from the defaults is Claude
///    Code. An id no list holds never moves a chat between backends on its own. `opus-5-1m` in a
///    settings file is a real example of such an id, and being wrong here costs a chat on a CLI
///    nobody chose.
///
/// Anything stored before this rule existed is a Claude Code model with no backend beside it,
/// which lands on Claude Code by question 1 and again by question 2. That is the whole of the
/// migration: there is no value to rewrite.
public struct DefaultBackend: Equatable, Sendable {
    public var kind: AgentKind
    /// Not always the effort that was asked for. Codex's levels belong to the model rather than
    /// to Bloom, so a stored `max` reaching `gpt-5.5`, which stops at `xhigh`, becomes that
    /// model's own default rather than a value the server refuses.
    public var effort: String

    public init(kind: AgentKind, effort: String) {
        self.kind = kind
        self.effort = effort
    }

    /// The three questions above, answered together with the effort that follows from them.
    ///
    /// - Parameters:
    ///   - model: the model actually in force, which is not always `app.model`: a repository's
    ///     settings file outranks the Models screen. See `ComposerDefaults.resolve`.
    ///   - running: the backend to keep when nothing recognises the model, which is question 3.
    ///   - codexModels: what `model/list` last answered, empty when it has not answered yet.
    public static func resolve(
        model: String,
        effort: String,
        app: AppDefaults,
        running: AgentKind = .claudeCode,
        codexModels: [CodexModel] = []
    ) -> DefaultBackend {
        let kind = model == app.model
            ? app.backend
            : self.kind(ofModel: model, running: running, codexModels: codexModels)
        return DefaultBackend(
            kind: kind,
            effort: self.effort(effort, on: kind, model: model, codexModels: codexModels)
        )
    }

    /// Questions 2 and 3 on their own, for a model that nobody recorded a backend for: the one
    /// picked out of a menu, or one a settings file states.
    ///
    /// `ComposerModelCatalog.backend(ofModel:current:)` is this function with the app's own list
    /// handed in, so the menu and the defaults cannot come to different answers about one id.
    public static func kind(
        ofModel model: String,
        running: AgentKind,
        codexModels: [CodexModel]
    ) -> AgentKind {
        if codexModels.contains(where: { $0.id == model }) { return .codex }
        if ClaudeModelRank.recognises(model) { return .claudeCode }
        return running
    }

    /// The effort a model actually takes, which on Codex is the model's business and not ours.
    ///
    /// Claude Code takes the same five levels for every model, so there is nothing to resolve
    /// there. Codex does not: `gpt-5.6-sol` takes six up to `ultra` and `gpt-5.5` four. A level
    /// the model does not list falls to that model's own default, which is why `CodexModel`
    /// carries one rather than everything assuming `high`.
    public static func effort(
        _ wanted: String,
        on kind: AgentKind,
        model: String,
        codexModels: [CodexModel]
    ) -> String {
        guard kind == .codex, let found = codexModels.first(where: { $0.id == model }) else {
            return wanted
        }
        return found.resolvedEffort(preferring: wanted)
    }
}
