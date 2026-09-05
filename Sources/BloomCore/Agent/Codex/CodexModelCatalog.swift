import Foundation

// MARK: - Model

/// One model Codex advertises through `model/list`.
///
/// This catalog is not an entitlement check. A model can appear here while the signed-in account
/// cannot use it.
///
/// **The efforts belong to the model, not to Bloom.** Claude Code takes the same five levels for
/// every model, so one flat list is right there. Codex does not: measured against codex-cli
/// 0.147.0, `gpt-5.6-sol` and `gpt-5.6-terra` accept six levels up to `ultra`, `gpt-5.6-luna`
/// five, and `gpt-5.5` and `gpt-5.2` four. A flat five-entry picker is wrong for three of the five
/// models on offer, in both directions: it hides a level two models have and offers levels three
/// models do not.
///
/// **Re-measured against codex-cli 0.153.0 on 2026-09-05, and every part of that list had moved.**
/// `gpt-6-astra` is there, as the account default, with the same six levels and a default of
/// `medium`; `gpt-5.2` has gone; `gpt-5.4-mini` and `gpt-5.3-codex-spark` have arrived with four
/// each. Not one line of Bloom changed to offer any of it, which is the whole case for fetching:
/// a generation nobody here had heard of was named, ranked and given its own effort picker on the
/// strength of what the CLI said. Both captures are kept as fixtures, and
/// `Tests/fixtures/codex-model-list-astra.json` is the newer one.
///
/// **What is on the wire and deliberately not read here.** Every model in that capture also
/// carries `serviceTiers` and `additionalSpeedTiers`: a `priority` tier the CLI calls "Fast",
/// worth 2x speed on `gpt-6-astra` and 1.5x on the `gpt-5.6` family, for more of the account's
/// usage allowance. `turn/start` takes it as `serviceTier` and `serviceTierForTurn`, so it is a
/// real control rather than an unreachable field, and Bloom sends neither, so every Codex turn
/// runs at standard speed. It is left out on purpose and not for want of a place to put it: it
/// spends the user's allowance faster, and Bloom's own "Fast mode" switch is already a different
/// thing on the other backend (Claude Code's `--thinking disabled`, see `AgentRunner`), so a
/// second control by that name needs a decision about both rather than a field being decoded.
public struct CodexModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    /// Not shown in a picker unless the user asked for hidden models. Kept rather than dropped, so
    /// a session already pinned to one still resolves its name.
    public let hidden: Bool
    public let supportedEfforts: [CodexReasoningEffort]
    public let defaultEffort: String
    public let inputModalities: [String]
    public let supportsPersonality: Bool

    public init(
        id: String,
        displayName: String,
        description: String = "",
        isDefault: Bool = false,
        hidden: Bool = false,
        supportedEfforts: [CodexReasoningEffort] = [],
        defaultEffort: String = "",
        inputModalities: [String] = [],
        supportsPersonality: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.hidden = hidden
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.inputModalities = inputModalities
        self.supportsPersonality = supportsPersonality
    }

    public var acceptsImages: Bool { inputModalities.contains("image") }

    public var effortIDs: [String] { supportedEfforts.map(\.id) }

    /// The effort to use when a session has one that this model does not take. Falls back to the
    /// model's own default, which is why the default is carried rather than assumed to be "high".
    public func resolvedEffort(preferring wanted: String) -> String {
        if effortIDs.contains(wanted) { return wanted }
        if !defaultEffort.isEmpty { return defaultEffort }
        return effortIDs.first ?? ""
    }

    static func decode(_ json: JSONValue) -> CodexModel? {
        guard let id = json["id"]?.stringValue else { return nil }
        let efforts = (json["supportedReasoningEfforts"]?.arrayValue ?? [])
            .compactMap(CodexReasoningEffort.decode)
        return CodexModel(
            id: id,
            displayName: json["displayName"]?.stringValue ?? id,
            description: json["description"]?.stringValue ?? "",
            isDefault: json["isDefault"]?.boolValue ?? false,
            hidden: json["hidden"]?.boolValue ?? false,
            supportedEfforts: efforts,
            defaultEffort: json["defaultReasoningEffort"]?.stringValue ?? "",
            inputModalities: (json["inputModalities"] ?? .null).stringArray,
            supportsPersonality: json["supportsPersonality"]?.boolValue ?? false
        )
    }

    static func decodeList(_ json: JSONValue) -> [CodexModel] {
        (json["data"]?.arrayValue ?? []).compactMap(CodexModel.decode)
    }
}

/// One reasoning level, with the sentence the server wrote for it. The description is worth
/// keeping: it is what a picker can put under the name instead of Bloom inventing one.
public struct CodexReasoningEffort: Sendable, Hashable, Identifiable {
    public let id: String
    public let description: String

    public init(id: String, description: String = "") {
        self.id = id
        self.description = description
    }

    /// `xhigh` reads as Xhigh with a naive title case, which is why the label is built here rather
    /// than by the generic one the composer uses for open-set ids.
    public var label: String {
        switch id {
        case "xhigh": "Extra high"
        default: id.capitalizedFirst
        }
    }

    static func decode(_ json: JSONValue) -> CodexReasoningEffort? {
        guard let id = json["reasoningEffort"]?.stringValue else { return nil }
        return CodexReasoningEffort(id: id, description: json["description"]?.stringValue ?? "")
    }
}

// MARK: - Catalog

/// The models Codex offers, fetched once and kept.
///
/// Fetched, never hardcoded. Conductor hardcodes its Codex model list and is already wrong about
/// it: the list it ships names `gpt-5.4`, which this account cannot select because it no longer
/// exists, while `gpt-5.6-sol`, `gpt-5.6-terra` and `gpt-5.6-luna` are missing from it entirely.
/// A list in the source is a list that goes stale between releases, and the picker is exactly
/// where being stale costs the user a model they are paying for.
///
/// `model/list` needs no account: it answered in full against a scratch `CODEX_HOME` with no
/// credentials at all, so the picker can be filled before anyone signs in.
///
/// Cached the way `SlashCommandIndex` results are: one fetch, shared by every caller that arrives
/// while it is in flight, held until `invalidate()`. An actor for the same reason `AgentCatalog`
/// is one, and with the same in-flight sharing, because a settings screen and a composer chip both
/// ask on appearance.
public actor CodexModelCatalog {
    /// How long a fetched list is trusted before it is fetched again. Long enough that opening the
    /// picker repeatedly costs nothing, short enough that a model added to the account shows up in
    /// the same sitting.
    public static let freshness: TimeInterval = 15 * 60

    private let fetch: @Sendable () async throws -> [CodexModel]
    private let now: @Sendable () -> Date

    private var cached: [CodexModel] = []
    private var fetchedAt: Date?
    private var inFlight: Task<[CodexModel], Error>?

    /// How many real fetches have happened, as opposed to cache hits and joins. Exists so the
    /// sharing can be asserted on rather than assumed.
    public private(set) var fetchCount = 0

    public init(
        fetch: @escaping @Sendable () async throws -> [CodexModel],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.now = now
    }

    /// The catalog the app uses: one short-lived `codex app-server` connection per fetch.
    ///
    /// A connection rather than a long-lived one, because this is asked for a few times an hour
    /// and holding a subprocess open between those is a process the user did not ask for.
    /// `cwd` is an empty folder Bloom owns rather than the home directory: listing models opens no
    /// file, and a CLI rooted at `~` is one that has been pointed at everything the user owns. See
    /// `AgentScratchDirectory`.
    public static func live(
        cwd: String = AgentScratchDirectory.current(), codexHome: String? = nil
    ) -> CodexModelCatalog {
        CodexModelCatalog(fetch: {
            let client = CodexClient(configuration: CodexClient.Configuration(
                cwd: cwd,
                codexHome: codexHome
            ))
            defer { Task { await client.stop() } }
            try await client.start()
            return try await client.listModels()
        })
    }

    /// Everything, hidden models included, sorted with the account default first.
    public func models() async throws -> [CodexModel] {
        if let fetchedAt, now().timeIntervalSince(fetchedAt) < Self.freshness, !cached.isEmpty {
            return cached
        }

        let task: Task<[CodexModel], Error>
        if let running = inFlight {
            task = running
        } else {
            fetchCount += 1
            let fetch = self.fetch
            task = Task { try await fetch() }
            inFlight = task
        }

        let models = try await task.value
        // Only file the result if this is still the fetch the catalog is waiting for: an
        // `invalidate()` during the await means somebody asked for a fresh look, and caching an
        // answer gathered before they asked would defeat exactly that.
        if inFlight == task {
            inFlight = nil
            cached = Self.sorted(models)
            fetchedAt = now()
        }
        return Self.sorted(models)
    }

    /// What a picker shows: the visible ones, default first.
    public func pickerModels() async throws -> [CodexModel] {
        try await models().filter { !$0.hidden }
    }

    /// The efforts one model takes, which is the list an effort picker must follow when the model
    /// chip changes. Empty when the model is not in the catalog, which a caller reads as "leave
    /// whatever the session already has alone" rather than as "no efforts".
    public func efforts(for modelID: String) async throws -> [CodexReasoningEffort] {
        try await models().first { $0.id == modelID }?.supportedEfforts ?? []
    }

    /// Drops the cache so a Refresh button does real work.
    public func invalidate() {
        cached = []
        fetchedAt = nil
        inFlight = nil
    }

    /// Whatever was last fetched, without fetching. For a picker that must draw now and would
    /// rather show a stale list than an empty one.
    public var lastKnown: [CodexModel] { cached }

    /// Most capable first. See `CodexModelRank`, which holds the rules and the reason the
    /// account's default no longer jumps the queue.
    static func sorted(_ models: [CodexModel]) -> [CodexModel] {
        CodexModelRank.ordered(models)
    }
}
