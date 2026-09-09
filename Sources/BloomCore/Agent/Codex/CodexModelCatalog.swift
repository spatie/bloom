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
