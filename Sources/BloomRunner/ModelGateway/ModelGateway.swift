import BloomCore
import Foundation

/// Keeps runbloom.app's model grants inside the trusted Runner and exchanges each for a separate
/// local bearer understood only by the loopback gateway. A local bearer is scoped to one turn,
/// agent, provider, model and operation, and disappears before the server turn is ended.
actor ModelGateway {
    static let capability = "opaque_model_grants_v1"
    static let renewalLeadTime: TimeInterval = 90

    struct Stream: Sendable {
        var requestID: UUID
        var provider: OpaqueModelGrant.Provider
        var response: RunbloomClient.ModelStreamResponse
    }

    struct Refusal: Error, Sendable {
        var status: Int
        var message: String
    }

    private struct Authority {
        var turnID: String
        var agent: AgentKind
        var grant: OpaqueModelGrant
        var renewal: Task<Void, Never>?
        var active: Set<UUID> = []
        var startsInFlight = 0
        var renewing = false
        var revoking = false
    }

    private let client: RunbloomClient
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> UUID
    private var authorities: [String: Authority] = [:]
    private var tokensByTurn: [String: Set<String>] = [:]
    private var closed = false

    init(
        client: RunbloomClient, now: @escaping @Sendable () -> Date = Date.init,
        identifier: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.client = client
        self.now = now
        self.identifier = identifier
    }

    func install(
        turnID: String, grants: [AgentKind: OpaqueModelGrant], baseURL: String
    ) async throws -> [AgentKind: [String: String]] {
        guard !closed else { throw Refusal(status: 503, message: "The local model gateway is stopping.") }
        guard !turnID.isEmpty, grants.count == 1, let (agent, grant) = grants.first else {
            throw Refusal(status: 403, message: "The turn did not receive one exact model grant.")
        }
        try validate(grant, for: agent)
        await revoke(turnID: turnID)
        let token = localToken()
        authorities[token] = Authority(turnID: turnID, agent: agent, grant: grant)
        tokensByTurn[turnID, default: []].insert(token)
        let renewal = Task { [weak self] in
            guard let self else { return }
            await self.renew(token: token)
        }
        authorities[token]?.renewal = renewal
        return [agent: environment(for: agent, token: token, baseURL: baseURL)]
    }

    /// Used by a trusted terminal-agent launcher. A terminal shell never receives this return
    /// value and has no local gateway bearer of its own.
    func issue(
        turnID: String, agent: AgentKind, model: String, baseURL: String,
        requestID: UUID
    ) async throws -> [String: String] {
        let grant = try await client.issueModelGrant(
            turnID: turnID, agent: agent, model: model, requestID: requestID
        )
        let installed = try await install(turnID: turnID, grants: [agent: grant], baseURL: baseURL)
        return installed[agent] ?? [:]
    }

    func open(token: String, path: String, body: Data, betas: [String] = []) async throws -> Stream {
        while authorities[token]?.renewing == true {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { throw CancellationError() }
        }
        guard !closed, var authority = authorities[token], !authority.revoking,
              authority.grant.expiresAt > now() else {
            throw Refusal(status: 401, message: "The local model gateway credential is invalid.")
        }
        guard paths(for: authority.grant.provider).contains(path) else {
            throw Refusal(status: 404, message: "This model operation is not available.")
        }
        let modelRequest = try sanitised(body, grant: authority.grant)
        let betas = try Self.anthropicBetas(betas, provider: authority.grant.provider)
        let requestID = identifier()
        authority.active.insert(requestID)
        authority.startsInFlight += 1
        authorities[token] = authority

        do {
            let response = try await client.startModelStream(
                grant: authority.grant, requestID: requestID, modelRequest: modelRequest,
                anthropicBeta: betas
            )
            guard var current = authorities[token], current.active.contains(requestID) else {
                try? await client.cancelModelStream(requestID: requestID, grant: authority.grant.token)
                throw CancellationError()
            }
            current.startsInFlight = max(0, current.startsInFlight - 1)
            if response.status == 403 {
                current.renewal?.cancel()
                authorities.removeValue(forKey: token)
                tokensByTurn[current.turnID]?.remove(token)
            } else {
                authorities[token] = current
            }
            return Stream(requestID: requestID, provider: authority.grant.provider, response: response)
        } catch {
            if var current = authorities[token] {
                current.active.remove(requestID)
                current.startsInFlight = max(0, current.startsInFlight - 1)
                authorities[token] = current
            }
            throw error
        }
    }

    func complete(token: String, requestID: UUID) {
        authorities[token]?.active.remove(requestID)
    }

    func cancel(token: String, requestID: UUID) async {
        guard var authority = authorities[token], authority.active.remove(requestID) != nil else { return }
        authorities[token] = authority
        try? await client.cancelModelStream(requestID: requestID, grant: authority.grant.token)
    }

    func revoke(turnID: String) async {
        let tokens = tokensByTurn.removeValue(forKey: turnID) ?? []
        var immediate: [(UUID, String)] = []
        var pendingRenewals: [(String, Task<Void, Never>)] = []
        for token in tokens {
            guard var authority = authorities[token] else { continue }
            authority.revoking = true
            authorities[token] = authority
            immediate += authority.active.map { ($0, authority.grant.token) }
            if authority.renewing, !authority.active.isEmpty, let renewal = authority.renewal {
                pendingRenewals.append((token, renewal))
            } else {
                authority.renewal?.cancel()
                authorities.removeValue(forKey: token)
            }
        }
        for (requestID, grant) in immediate {
            try? await client.cancelModelStream(requestID: requestID, grant: grant)
        }
        for (token, renewal) in pendingRenewals {
            await renewal.value
            guard let authority = authorities.removeValue(forKey: token) else { continue }
            authority.renewal?.cancel()
            for requestID in authority.active {
                try? await client.cancelModelStream(requestID: requestID, grant: authority.grant.token)
            }
        }
    }

    func shutdown() async {
        closed = true
        let turns = Array(tokensByTurn.keys)
        for turn in turns { await revoke(turnID: turn) }
    }

    private func renew(token: String) async {
        while !Task.isCancelled {
            guard let authority = authorities[token] else { return }
            let delay = authority.grant.expiresAt.timeIntervalSince(now()) - Self.renewalLeadTime
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            while authorities[token]?.startsInFlight ?? 0 > 0 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard var current = authorities[token], current.grant.expiresAt > now() else {
                remove(token: token)
                return
            }
            current.renewing = true
            authorities[token] = current
            let old = current.grant
            let requestID = identifier()
            let renewalBody: Data
            do {
                renewalBody = try client.modelGrantRenewalBody(grant: old.token, requestID: requestID)
            } catch {
                remove(token: token)
                return
            }
            var rotated: OpaqueModelGrant?
            while rotated == nil, !Task.isCancelled {
                do {
                    rotated = try await client.renewModelGrant(
                        turnID: current.turnID, body: renewalBody
                    )
                } catch let error as RunbloomError {
                    if case .refused(403, "model_grant_invalid", _, _, _) = error {
                        remove(token: token)
                        return
                    }
                    guard let latest = authorities[token], latest.grant.expiresAt > now() else {
                        remove(token: token)
                        return
                    }
                    do { try await Task.sleep(for: retryDelay(error)) } catch { return }
                } catch {
                    guard (authorities[token]?.grant.expiresAt ?? .distantPast) > now() else {
                        remove(token: token)
                        return
                    }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            guard let rotated else { return }
            do {
                try validate(rotated, for: current.agent)
                guard rotated.revision == old.revision + 1, rotated.token != old.token,
                      rotated.provider == old.provider, rotated.model == old.model,
                      rotated.operation == old.operation else {
                    throw Refusal(status: 403, message: "The renewed model grant changed its binding.")
                }
            } catch {
                remove(token: token)
                return
            }
            guard var latest = authorities[token], latest.grant.token == old.token,
                  latest.grant.revision == old.revision else { continue }
            latest.grant = rotated
            latest.renewing = false
            authorities[token] = latest
            if latest.revoking { return }
        }
    }

    private func retryDelay(_ error: RunbloomError) -> Duration {
        if case .refused(_, _, _, _, let retryAfter) = error, let retryAfter {
            return .seconds(max(1, retryAfter))
        }
        return .seconds(5)
    }

    private func remove(token: String) {
        guard let authority = authorities.removeValue(forKey: token) else { return }
        authority.renewal?.cancel()
        tokensByTurn[authority.turnID]?.remove(token)
    }

    private func validate(_ grant: OpaqueModelGrant, for agent: AgentKind) throws {
        let expected: (OpaqueModelGrant.Provider, OpaqueModelGrant.Operation)? = switch agent {
        case .claudeCode: (.anthropic, .anthropicMessagesStream)
        case .codex: (.openai, .openAIResponsesStream)
        case .grok: (.xai, .xAIResponsesStream)
        case .cursor, .openCode: nil
        }
        guard grant.version == "opaque_model_grant_v1", grant.token.count == 64,
              grant.revision > 0, !grant.model.isEmpty, grant.expiresAt > now(),
              let expected, grant.provider == expected.0, grant.operation == expected.1 else {
            throw Refusal(status: 403, message: "The model grant does not match this agent.")
        }
    }

    private func sanitised(_ data: Data, grant: OpaqueModelGrant) throws -> Data {
        guard data.count <= 16 * 1_048_576,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Refusal(status: 422, message: "The model request is not a valid JSON object.")
        }
        for key in ["grant", "operation", "provider", "request_id", "version"] where object[key] != nil {
            throw Refusal(status: 422, message: "The model request contains a reserved field.")
        }
        if let value = object.removeValue(forKey: "model") {
            guard let model = value as? String, model == grant.model else {
                throw Refusal(status: 403, message: "The model request does not match its grant.")
            }
        }
        if let value = object.removeValue(forKey: "stream") {
            guard let stream = value as? Bool, stream else {
                throw Refusal(status: 422, message: "Only streaming model requests are accepted.")
            }
        }
        for key in ["store", "background"] {
            if let value = object.removeValue(forKey: key) {
                guard let enabled = value as? Bool, !enabled else {
                    throw Refusal(status: 422, message: "Stored or background model requests are not accepted.")
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Claude Code names the request fields it sends in `anthropic-beta`, and Anthropic refuses a
    /// field whose beta is not named: without this every turn came back 400 with
    /// "context_management: Extra inputs are not permitted", so no model request through the
    /// gateway had ever succeeded. Passed on as names only, never as a header, so runbloom.app
    /// decides what reaches the provider. The header may repeat and each value is a list.
    static func anthropicBetas(
        _ values: [String], provider: OpaqueModelGrant.Provider
    ) throws -> [String] {
        let names = values.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        guard provider == .anthropic else {
            throw Refusal(status: 422, message: "Beta features are only forwarded to Anthropic.")
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard names.count <= 32, names.allSatisfy({ $0.count <= 64 && $0.allSatisfy(allowed.contains) }) else {
            throw Refusal(status: 422, message: "The model request names an invalid beta feature.")
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func paths(for provider: OpaqueModelGrant.Provider) -> Set<String> {
        switch provider {
        case .anthropic: ["/messages", "/v1/messages"]
        case .openai, .xai: ["/responses", "/v1/responses"]
        }
    }

    private func environment(for agent: AgentKind, token: String, baseURL: String) -> [String: String] {
        switch agent {
        case .claudeCode:
            ["ANTHROPIC_API_KEY": token, "ANTHROPIC_BASE_URL": baseURL]
        case .codex:
            ["OPENAI_API_KEY": token, "OPENAI_BASE_URL": baseURL + "/v1"]
        case .grok:
            ["XAI_API_KEY": token, "GROK_XAI_API_BASE_URL": baseURL + "/v1"]
        case .cursor, .openCode:
            [:]
        }
    }

    private func localToken() -> String {
        (identifier().uuidString + identifier().uuidString)
            .replacingOccurrences(of: "-", with: "").lowercased()
    }
}
