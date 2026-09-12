import Foundation
import BloomClient

public typealias GrokModel = BloomClient.GrokModel
public typealias GrokReasoningEffort = BloomClient.GrokReasoningEffort

/// The models Grok offers, fetched once and kept.
///
/// Fetched from ACP `initialize`, which already carries `modelState` without opening a session
/// and without spending a turn. A short-lived `grok agent --no-leader stdio` is spawned per
/// fetch, the same shape as `CodexModelCatalog`, so listing models is not a process the user
/// did not ask for hanging around between picker openings.
public actor GrokModelCatalog {
    public static let freshness = AgentModelCache<GrokModel>.freshness

    private let cache: AgentModelCache<GrokModel>

    public var fetchCount: Int { get async { await cache.fetchCount } }

    public init(
        fetch: @escaping @Sendable () async throws -> [GrokModel],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        cache = AgentModelCache(fetch: { Self.sorted(try await fetch()) }, now: now)
    }

    public static func live(
        cwd: String = AgentScratchDirectory.current(),
        store: Store? = nil,
        makeClient: @escaping @Sendable (GrokClient.Configuration) -> GrokClient = GrokRunner.spawn
    ) -> GrokModelCatalog {
        GrokModelCatalog(fetch: {
            let stored = try await store?.setting(AgentCatalog.executablePathSettingKey(.grok))
            let client = makeClient(GrokClient.Configuration(
                executable: AgentCatalog.executable(for: .grok, override: stored),
                cwd: cwd
            ))
            defer { Task { await client.stop() } }
            try await client.start()
            return await client.advertisedModels()
        })
    }

    public func models() async throws -> [GrokModel] {
        try await cache.models()
    }

    public func pickerModels() async throws -> [GrokModel] {
        try await models()
    }

    public func invalidate() async {
        await cache.invalidate()
    }

    public var lastKnown: [GrokModel] { get async { await cache.lastKnown } }

    static func sorted(_ models: [GrokModel]) -> [GrokModel] {
        GrokModelRank.ordered(models)
    }
}
