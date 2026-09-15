import Foundation
import BloomClient

public typealias CodexModel = BloomClient.CodexModel
public typealias CodexReasoningEffort = BloomClient.CodexReasoningEffort

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
    public static let freshness = AgentModelCache<CodexModel>.freshness

    private let cache: AgentModelCache<CodexModel>

    public var fetchCount: Int { get async { await cache.fetchCount } }

    public init(
        fetch: @escaping @Sendable () async throws -> [CodexModel],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        cache = AgentModelCache(fetch: { Self.sorted(try await fetch()) }, now: now)
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

    /// Everything, hidden models included, in the backend's capability order.
    public func models() async throws -> [CodexModel] {
        try await cache.models()
    }

    /// What a picker shows: the visible models, preserving their capability order.
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
    public func invalidate() async {
        await cache.invalidate()
    }

    /// Whatever was last fetched, without fetching. For a picker that must draw now and would
    /// rather show a stale list than an empty one.
    public var lastKnown: [CodexModel] { get async { await cache.lastKnown } }

    /// Most capable first. See `CodexModelRank`, which holds the rules and the reason the
    /// account's default no longer jumps the queue.
    static func sorted(_ models: [CodexModel]) -> [CodexModel] {
        CodexModelRank.ordered(models)
    }
}
