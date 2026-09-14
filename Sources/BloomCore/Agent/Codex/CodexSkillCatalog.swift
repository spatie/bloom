import Foundation

/// Uses Codex's enabled skill list instead of walking a plugin cache full of old versions.
/// One catalogue belongs to one workspace. Brief caching also covers failures, so typing `/`
/// repeatedly does not keep launching an unavailable executable.
public actor CodexSkillCatalog {
    private let fetch: @Sendable () async throws -> [SlashCommand]
    private let now: @Sendable () -> Date
    private var cached: [SlashCommand]?
    private var fetchedAt: Date?
    private var running: Task<[SlashCommand]?, Never>?

    public init(
        fetch: @escaping @Sendable () async throws -> [SlashCommand],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fetch = fetch
        self.now = now
    }

    public static func live(project: String, codexHome: String? = nil) -> CodexSkillCatalog {
        CodexSkillCatalog(fetch: {
            let client = CodexClient(configuration: .init(cwd: project, codexHome: codexHome))
            // Bound the handshake as well as the request, and always reap this short-lived child.
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await client.stop()
            }
            do {
                try await client.start()
                let response = try await client.send("skills/list", params: .object([
                    "cwds": .array([.string(project)]),
                    "forceReload": .bool(true),
                ]), timeout: .seconds(5))
                guard response["data"]?.arrayValue?.contains(where: {
                    $0["cwd"]?.stringValue == project && $0["skills"]?.arrayValue != nil
                }) == true else {
                    throw CodexClientError.unexpectedResult(method: "skills/list")
                }
                deadline.cancel()
                await client.stop()
                return decode(response, project: project)
            } catch {
                deadline.cancel()
                await client.stop()
                throw error
            }
        })
    }

    public func skills() async -> [SlashCommand]? {
        if let fetchedAt, now().timeIntervalSince(fetchedAt) < 30 { return cached }
        if let running { return await running.value }
        let fetch = self.fetch
        let task = Task { try? await fetch() }
        running = task
        let found = await task.value
        cached = found
        fetchedAt = now()
        running = nil
        return found
    }

    static func decode(_ response: JSONValue, project: String) -> [SlashCommand] {
        let rows = response["data"]?.arrayValue ?? []
        return rows.filter { $0["cwd"]?.stringValue == project }.flatMap { row in
            (row["skills"]?.arrayValue ?? []).compactMap { skill in
                guard skill["enabled"]?.boolValue == true,
                      let rawName = skill["name"]?.stringValue,
                      let name = SlashCommandIndex.sanitised(rawName),
                      let path = skill["path"]?.stringValue else { return nil }
                let plugin = skill["pluginId"]?.stringValue
                    .map { String($0.prefix { $0 != "@" }) }
                    .flatMap(SlashCommandIndex.sanitised)
                let scope: SlashCommand.Scope = plugin.map { .plugin($0) }
                    ?? (skill["scope"]?.stringValue == "repo" ? .project : .user)
                let qualified = plugin.map { name.hasPrefix("\($0):") ? name : "\($0):\(name)" } ?? name
                return SlashCommand(
                    name: qualified,
                    detail: skill["interface"]?["shortDescription"]?.stringValue
                        ?? skill["description"]?.stringValue ?? "",
                    kind: .skill, scope: scope, path: path
                )
            }
        }
    }
}
