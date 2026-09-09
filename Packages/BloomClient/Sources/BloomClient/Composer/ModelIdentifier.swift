import Foundation

/// What a stored model string actually names: an id a CLI can be handed, and the backend that
/// runs it.
///
/// Model ids are an open set, and deliberately so. One reaches Bloom verbatim from places Bloom
/// does not own (a repository's `models.default`, `~/.conductor/settings.toml`, a bridge call),
/// and the rule everywhere else is that an id nobody recognises is kept rather than rewritten:
/// the CLI may well accept it, and guessing would break a model somebody is paying for. See
/// `ComposerOption.adding` and `ModelAlias`.
///
/// **One shape breaks that rule, and it is the bug this file was written for.** A settings file
/// that has to name a model for either CLI in a single string writes the backend in front of it,
/// and `codex:gpt-5.6-sol` arrived in a `models.default` that way. Nothing recognised it, so
/// `DefaultBackend`'s last question parked it on whatever was running, which is Claude Code for a
/// chat being opened. Three things followed, and a user reported all three at once:
///
/// 1. The composer's model menu grew a fifth row **inside its Claude Code section** reading
///    "Codex:gpt 5.6 Sol", which is `ModelLabel.readable("codex:gpt-5.6-sol")` and is how the
///    stored string was identified from a screenshot.
/// 2. The chat was launched with `--model codex:gpt-5.6-sol`, which is not a model, so it ran on
///    Claude Code's own default rather than on anything the menu said.
/// 3. Changing the model in Settings, Models did nothing, because a repository's settings file
///    outranks that screen (`ComposerDefaults.resolve`) and put the same string straight back.
///
/// A colon is what makes this safe to read rather than guess at: no id either CLI ships has one
/// in it. `claude-opus-5[1m]`, `opus-5-1m` and `gpt-5.6-sol` pass through untouched, and so does
/// `internal-preview-3:whatever`, because the part before the colon is only taken off when it
/// names a backend Bloom actually has.
///
/// The second thing it reads back is a **label written where an id belongs**: a value that
/// matches a fetched Codex model's id or display name once both are stripped to letters and
/// digits is that model, so `Codex: GPT-5.6 Sol` resolves to `gpt-5.6-sol` rather than being
/// stored as prose. Nothing is invented from a label alone; the answer has to already be in the
/// account's own list.
public struct ModelIdentifier: Equatable, Sendable {
    /// The id a CLI can be handed, with any backend name taken off the front.
    public var model: String
    /// Whose model it is, or nil when nothing here recognises it and the caller's own answer
    /// stands. See `DefaultBackend.kind(ofModel:running:codexModels:)`.
    public var kind: AgentKind?
    /// Whether the string named its backend itself.
    ///
    /// It is kept apart from `kind` because it outranks everything else: a file writing `codex:`
    /// is stating the backend rather than implying it, so it beats a backend recorded beside the
    /// model in Settings, while a model merely *recognised* from a list does not.
    public var namesBackend: Bool

    public init(model: String, kind: AgentKind? = nil, namesBackend: Bool = false) {
        self.model = model
        self.kind = kind
        self.namesBackend = namesBackend
    }

    /// Reads a stored string for everything it says about itself.
    ///
    /// - Parameter codexModels: what `model/list` last answered, empty when it has not answered
    ///   yet. Empty costs only the label reading and the Codex half of the recognition; a string
    ///   that names its own backend is read without any list at all, which is the whole reason
    ///   the namespace is trusted over a lookup.
    public static func resolve(_ raw: String, codexModels: [CodexModel] = []) -> ModelIdentifier {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ModelIdentifier(model: raw) }

        guard let (named, rest) = namespaced(trimmed) else {
            // Nothing named, so the lists answer, in the order `DefaultBackend` has always asked
            // them in: Codex's fetched list is authoritative for its own ids, and
            // `ClaudeModelRank` knows the four families.
            if let match = codexModel(named: trimmed, in: codexModels) {
                return ModelIdentifier(model: match, kind: .codex)
            }
            if ClaudeModelRank.recognises(trimmed) {
                return ModelIdentifier(model: trimmed, kind: .claudeCode)
            }
            return ModelIdentifier(model: trimmed)
        }

        // The backend is settled; only the id still has to be read, and only Codex has a list to
        // read it against. A Claude Code id is left exactly as it was, because `ModelAlias` is
        // what translates those and it is the only thing that should.
        let model = named == .codex ? codexModel(named: rest, in: codexModels) ?? rest : rest
        return ModelIdentifier(model: model, kind: named, namesBackend: true)
    }

    /// What a session holding this model should be corrected to, or nil when it is already right.
    ///
    /// The composer runs this every time a chat is opened, because a chat that was written one of
    /// these before the rule existed would otherwise sit on it for ever: its model is not a model,
    /// so it cannot run, and the menu's own way back (`ComposerOption.adding`) offers the broken
    /// id in whichever section it was parked in.
    ///
    /// - Parameter hasSpoken: whether the chat has a thread on its backend's server. A chat that
    ///   has keeps its backend whatever the id says, because moving it would leave a transcript in
    ///   one CLI's vocabulary and a thread id naming the other's, which is the whole reason
    ///   `BackendChange` forks rather than changes. Only the id is corrected there, and the menu
    ///   then offers the move as the fork it is.
    public static func correction(
        model raw: String,
        on kind: AgentKind,
        hasSpoken: Bool,
        codexModels: [CodexModel] = []
    ) -> ModelIdentifier? {
        let resolved = resolve(raw, codexModels: codexModels)
        let moved = !hasSpoken && resolved.namesBackend ? resolved.kind : nil
        let settled = moved ?? kind
        guard resolved.model != raw || settled != kind else { return nil }
        return ModelIdentifier(model: resolved.model, kind: settled, namesBackend: resolved.namesBackend)
    }

    // MARK: - Reading the parts

    /// The backend written in front of a colon, and what is left of the id, or nil when the string
    /// does not name one.
    private static func namespaced(_ value: String) -> (AgentKind, String)? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let head = normalised(String(value[value.startIndex..<colon]))
        // Only a backend that can actually run a chat, which is the same guard
        // `BackendChange.decide` keeps from the other side: a string is not allowed to put a chat
        // on something with no runner, however clearly it names it.
        guard let kind = AgentKind.runnable.first(where: { names(head, $0) }) else { return nil }
        let rest = value[value.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `codex:` on its own names no model, so there is nothing to take the name off.
        guard !rest.isEmpty else { return nil }
        return (kind, rest)
    }

    /// The three spellings of a backend a file could reasonably use: the key Bloom stores, the
    /// name a person reads, and the command they type. All three normalise to the same shape, so
    /// "Codex", "codex", "Claude Code" and "claude-code" are all understood.
    private static func names(_ head: String, _ kind: AgentKind) -> Bool {
        !head.isEmpty && [kind.rawValue, kind.label, kind.executableName]
            .contains { normalised($0) == head }
    }

    /// A fetched model whose id or display name is this value once both are stripped to letters
    /// and digits, which is what reads a label back as the id it was rendered from.
    private static func codexModel(named value: String, in models: [CodexModel]) -> String? {
        let wanted = normalised(value)
        guard !wanted.isEmpty else { return nil }
        if let exact = models.first(where: { normalised($0.id) == wanted }) { return exact.id }
        return models.first { normalised($0.displayName) == wanted }?.id
    }

    /// Letters and digits, lowercased. Every separator these ids and labels use goes, because the
    /// one thing a rendered label reliably loses is which separator was there: `gpt-5.6-sol`,
    /// `GPT-5.6 Sol` and `gpt 5.6 sol` are one model written three ways.
    private static func normalised(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
