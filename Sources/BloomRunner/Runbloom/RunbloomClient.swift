import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import NIOHTTP1

/// Bloom Runner's calls to runbloom.app's machine API, each authorised by the workspace secret.
///
/// Only the transport and the contract live here: the paths, the bodies, what each answer decodes
/// to and which failure it is. What to do about a failure (retry a report, block a prompt, pause
/// the queue) belongs to the callers, `ReportDelivery` and `RunbloomTurns`, which is why every
/// method throws a `RunbloomError` rather than deciding. See docs/REMOTE-WORKSPACES.md, "The
/// machine-facing endpoints on runbloom.app".
///
/// The `HTTPClient` is passed in rather than made here, because it owns an event loop and has to
/// be shut down by whoever owns the process, and one client is shared by every caller.
public struct RunbloomClient: Sendable {
    struct TransportResponse: Sendable {
        var status: Int
        var body: Data
        var retryAfter: String?
    }
    struct ModelStreamResponse: Sendable {
        var status: Int
        var contentType: String?
        var retryAfter: String?
        var body: HTTPClientResponse.Body
    }
    /// `{base}/api/machine/workspaces/{id}`, built once. Held as the path rather than the id so
    /// the id is never mistaken for one of Bloom's own.
    private let workspaceURL: String
    private let secret: WorkspaceSecret
    private let identity: MachineIdentitySigner
    private let http: HTTPClient
    private let timeout: TimeAmount
    /// Nothing runbloom.app answers here is near this; it only bounds a misbehaving proxy.
    static let largestAnswer = 1 << 20

    /// Every call is small, and a queue or a flush before sleep waits on it, so a hung connection
    /// must not hold either for longer than `timeout`. A refused connection is retried by
    /// `HTTPClient` until then too, which is why a test passes something shorter.
    public init(
        baseURL: String, workspaceID: String, secret: String, http: HTTPClient,
        identity: MachineIdentitySigner? = nil, timeout: Duration = .seconds(15)
    ) {
        self.init(
            baseURL: baseURL, workspaceID: workspaceID, secret: WorkspaceSecret(fixed: secret),
            http: http, identity: identity, timeout: timeout
        )
    }

    public init(
        baseURL: String, workspaceID: String, secret: WorkspaceSecret, http: HTTPClient,
        identity: MachineIdentitySigner? = nil, timeout: Duration = .seconds(15)
    ) {
        let (seconds, attoseconds) = timeout.components
        self.timeout = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let target = "/api/machine/workspaces/\(workspaceID)"
        workspaceURL = base + target
        self.secret = secret
        self.identity = identity ?? MachineIdentitySigner.generated(workspaceID: WorkspaceID(workspaceID))
        self.http = http
    }

    public func registerMachineIdentity(registrationToken: String) async throws -> MachineIdentityDescriptor {
        let registration = try await identity.registration()
        let response = try await sendOnce(
            .POST, "/machine-identity", body: registration.body,
            headers: [
                "X-Bloom-Identity-Registration": registrationToken,
                "X-Bloom-Proof-Version": "1",
                "X-Bloom-Proof-Timestamp": String(registration.timestamp),
                "X-Bloom-Proof-Request-Id": registration.requestID,
            ], expecting: [201], signsRequest: false
        )
        let answer = try decode(MachineIdentityResponse.self, response.body, status: response.status)
        let descriptor = await identity.descriptor
        guard answer.version == 1, answer.keyID == descriptor.keyID else {
            throw MachineIdentityError.mismatchedKey
        }
        return descriptor
    }

    public func rotateMachineIdentity() async throws -> MachineIdentityDescriptor {
        let rotation = try await identity.prepareRotation()
        let response = try await sendOnce(
            .PUT, "/machine-identity", body: rotation.body, headers: [:], expecting: [200],
            proof: rotation.headers
        )
        let answer = try decode(MachineIdentityResponse.self, response.body, status: response.status)
        guard let pending = await identity.pendingDescriptor,
              answer.version == 1, answer.keyID == pending.keyID else {
            throw MachineIdentityError.mismatchedKey
        }
        try await identity.commitRotation()
        return await identity.descriptor
    }

    func verifyMachineIdentity(usingPending: Bool = false) async throws {
        _ = try await sendOnce(
            .GET, "/members", body: nil, headers: [:], expecting: [200],
            usesPendingProof: usingPending
        )
    }

    public func postSummary(_ body: Data) async throws {
        _ = try await send(.POST, "/summary", body: body, expecting: [204])
    }

    public func postUsage(_ body: Data) async throws {
        _ = try await send(.POST, "/usage", body: body, expecting: [204])
    }

    /// Everybody with access to this workspace, for resolving and validating a mention.
    ///
    /// **A pull rather than a push, and refetching is just asking again.** A machine holding a list
    /// from three weeks ago refuses a colleague who joined last week, which is the same failure as
    /// refusing an id outright, only slower and harder to see. No addresses in it: see
    /// `WorkspaceMember`.
    public func members() async throws -> [WorkspaceMember] {
        struct Answer: Decodable { var members: [WorkspaceMember]? }
        let data = try await send(.GET, "/members", expecting: [200])
        return try decode(Answer.self, data, status: 200).members ?? []
    }

    /// Tells runbloom.app that somebody was addressed, so it can mail them if they were not here.
    ///
    /// **Its own call rather than folded into a report, because it causes mail.** Anything
    /// coalesced, retried for unrelated reasons or replayed would eventually send two emails or
    /// none. runbloom.app dedupes on the message id **per addressed person**, so a retry is free
    /// and a partial delivery cannot double-mail or lose somebody.
    ///
    /// **The id must never be reused for a different message**: a reused one is silently treated as
    /// a retry and nobody is mailed, which fails without a symptom. It is a ULID minted once when
    /// the row is written and kept on the row, so a retry after a restart sends the same one.
    public func reportAddressed(_ body: Data) async throws {
        _ = try await send(.POST, "/addressed", body: body, expecting: [200, 202, 204])
    }

    public func environment() async throws -> MachineEnvironmentResponse {
        let data = try await send(.GET, "/environment", expecting: [200])
        return try decode(MachineEnvironmentResponse.self, data, status: 200)
    }

    /// Issues and consumes one scope-bound handoff. Neither request is replayed by this client.
    /// If consumption has an ambiguous result, the caller starts a new setup attempt or service
    /// launch with a new UUID instead of risking reuse of the consumed authority.
    public func secrets(for scope: SecretHandoffScope, now: Date = Date()) async throws -> [String: String] {
        let issued = try await sendOnce(
            .POST, "/secret-handoffs", body: try scope.issueBody, headers: [:], expecting: [200, 201]
        )
        let handoff = try decode(SecretHandoff.self, issued.body, status: issued.status)
        guard handoff.expiresAt > now else {
            await cancelSecretHandoff(handoff.id)
            throw RunbloomError.unexpected(status: issued.status)
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["version": 1])
            let data = try await sendOnce(
                .POST, "/secret-handoffs/\(handoff.id)/consume", body: body, headers: [:], expecting: [200]
            ).body
            return try decode(SecretHandoffConsumption.self, data, status: 200).secrets
        } catch {
            await cancelSecretHandoff(handoff.id)
            throw error
        }
    }

    public func syncServiceManifest(_ services: [RemoteProjectSettings.Service]) async throws {
        let listed = services.map { ["id": $0.id, "name": $0.name] }
        let body = try JSONSerialization.data(withJSONObject: ["version": 1, "services": listed])
        let response = try await send(.PUT, "/service-manifest", body: body, expecting: [204])
        guard response.isEmpty else { throw RunbloomError.unexpected(status: 204) }
    }

    private func cancelSecretHandoff(_ id: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["version": 1])
        guard let body else { return }
        // A fresh unstructured task can still make the best-effort cancellation when the calling
        // task itself was cancelled. It is awaited, so its lifetime remains bounded here.
        await Task {
            _ = try? await sendOnce(
                .DELETE, "/secret-handoffs/\(id)", body: body, headers: [:], expecting: [204]
            )
        }.value
    }

    /// Registers a turn or a terminal session while the prompter's token is fresh, and answers
    /// runbloom.app's turn id. `chatID` and `agent` go as JSON null for a terminal, as the contract
    /// has them present either way.
    public func registerTurn(
        kind: RemoteTurnKind, chatID: String?, agent: AgentKind?, model: String?, sessionToken: String
    ) async throws -> String {
        struct Answer: Decodable {
            var turnID: String
            enum CodingKeys: String, CodingKey { case turnID = "turn_id" }
        }
        let body: [String: Any] = [
            "kind": kind.rawValue,
            "session_token": sessionToken,
            "chat_id": chatID ?? NSNull(),
            "agent": agent?.wireName ?? NSNull(),
            "model": model ?? NSNull(),
        ]
        let data = try await send(.POST, "/turns", body: JSONSerialization.data(withJSONObject: body), expecting: [201, 200])
        return try decode(Answer.self, data, status: 201).turnID
    }

    public func startTurn(_ id: String) async throws -> RunbloomTurnStart {
        let data = try await send(.POST, "/turns/\(id)/start", expecting: [200])
        return try decode(RunbloomTurnStartBody.self, data, status: 200).start
    }

    public func issueModelGrant(
        turnID: String, agent: AgentKind, model: String, requestID: UUID
    ) async throws -> OpaqueModelGrant {
        struct Answer: Decodable { var modelGrant: OpaqueModelGrant
            enum CodingKeys: String, CodingKey { case modelGrant = "model_grant" }
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "version": "opaque_model_grant_v1",
            "agent": agent.wireName,
            "model": model,
            "request_id": requestID.uuidString.lowercased(),
        ], options: [.sortedKeys])
        let data = try await send(
            .POST, "/turns/\(turnID)/model-grants", body: body, expecting: [201]
        )
        return try decode(Answer.self, data, status: 201).modelGrant
    }

    func renewModelGrant(
        turnID: String, grant: String, requestID: UUID
    ) async throws -> OpaqueModelGrant {
        try await renewModelGrant(
            turnID: turnID, body: modelGrantRenewalBody(grant: grant, requestID: requestID)
        )
    }

    func modelGrantRenewalBody(grant: String, requestID: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": "opaque_model_grant_v1",
            "grant": grant,
            "request_id": requestID.uuidString.lowercased(),
        ], options: [.sortedKeys])
    }

    func renewModelGrant(turnID: String, body: Data) async throws -> OpaqueModelGrant {
        struct Answer: Decodable { var modelGrant: OpaqueModelGrant
            enum CodingKeys: String, CodingKey { case modelGrant = "model_grant" }
        }
        let data = try await send(
            .POST, "/turns/\(turnID)/model-grant-renewals", body: body, expecting: [200]
        )
        return try decode(Answer.self, data, status: 200).modelGrant
    }

    func startModelStream(
        grant: OpaqueModelGrant, requestID: UUID, modelRequest: Data, anthropicBeta: [String] = []
    ) async throws -> ModelStreamResponse {
        let request = try JSONSerialization.jsonObject(with: modelRequest)
        var fields: [String: Any] = [
            "version": "opaque_model_grant_v1",
            "grant": grant.token,
            "request_id": requestID.uuidString.lowercased(),
            "operation": grant.operation.rawValue,
            "provider": grant.provider.rawValue,
            "model": grant.model,
            "model_request": request,
        ]
        if !anthropicBeta.isEmpty { fields["anthropic_beta"] = anthropicBeta }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try await sendStreamingOnce(.POST, "/model-gateway/streams", body: body)
    }

    func cancelModelStream(requestID: UUID, grant: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "version": "opaque_model_grant_v1",
            "grant": grant,
        ], options: [.sortedKeys])
        _ = try await send(
            .DELETE, "/model-gateway/requests/\(requestID.uuidString.lowercased())",
            body: body, expecting: [204]
        )
    }

    /// Idempotent on runbloom.app, so a caller that is unsure whether an earlier attempt landed
    /// can simply send it again.
    public func endTurn(_ id: String) async throws {
        _ = try await send(.DELETE, "/turns/\(id)", expecting: [204, 200])
    }

    /// The machine actor's read-only grant for Runner-owned bootstrap work. The response bearer is
    /// held by the v2 broker only and is never written to Store or configuration.
    public func bootstrapGithubCredentialGrant() async throws -> PersonBoundGithubGrant {
        struct Answer: Decodable { var grant: PersonBoundGithubGrantBody }
        let data = try await sendOnce(
            .POST, "/github-credential-grants/bootstrap", body: nil, headers: [:], expecting: [201]
        ).body
        guard let grant = try decode(Answer.self, data, status: 201).grant.grant else {
            throw RunbloomError.unexpected(status: 201)
        }
        return grant
    }

    /// Exchanges exactly one rotating v2 grant for exactly one typed operation. There is no
    /// repository or identity in the request because both are bound to the opaque grant by 7B.
    public func githubCredentials(
        grant: String, operation: PersonBoundGithubOperation, requestID: UUID
    ) async throws -> PersonBoundGithubCredentials {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant": grant,
            "operation": operation.rawValue,
            "request_id": requestID.uuidString.lowercased(),
        ])
        // Rotating grants are not replayable. Even an authentication failure is returned to the
        // broker without the usual machine-secret retry because the server may have consumed it.
        let data = try await sendOnce(
            .POST, "/github-credentials", body: body, headers: [:], expecting: [200]
        ).body
        guard let issued = try decode(PersonBoundGithubCredentialsBody.self, data, status: 200).issued else {
            throw RunbloomError.unexpected(status: 200)
        }
        return issued
    }

    // MARK: - Transport

    /// A call refused for its secret is sent once more when workspace.json now holds another one,
    /// because runbloom.app rotated it and the control call saying so has not arrived (or never
    /// will). Every call here is idempotent on runbloom.app or harmless to repeat, which is what
    /// makes sending it twice safe.
    func send(_ method: HTTPMethod, _ path: String, body: Data? = nil, headers: [String: String] = [:],
              expecting success: Set<Int>) async throws -> Data {
        try await sendResponse(method, path, body: body, headers: headers, expecting: success).body
    }

    func sendResponse(_ method: HTTPMethod, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                      expecting success: Set<Int>) async throws -> TransportResponse {
        do {
            return try await sendOnce(method, path, body: body, headers: headers, expecting: success)
        } catch let error as RunbloomError where error.isTerminal && secret.reload() {
            return try await sendOnce(method, path, body: body, headers: headers, expecting: success)
        }
    }

    private func sendOnce(
        _ method: HTTPMethod, _ path: String, body: Data?, headers: [String: String],
        expecting success: Set<Int>, signsRequest: Bool = true,
        proof suppliedProof: MachineIdentityProofHeaders? = nil,
        usesPendingProof: Bool = false
    ) async throws -> TransportResponse {
        let request = try await request(
            method, path, body: body, headers: headers, signsRequest: signsRequest,
            proof: suppliedProof, usesPendingProof: usesPendingProof
        )

        let status: Int
        let answer: Data
        let retryAfter: String?
        do {
            let response = try await http.execute(request, timeout: timeout)
            status = Int(response.status.code)
            retryAfter = response.headers.first(name: "Retry-After")
            let buffer = try await response.body.collect(upTo: Self.largestAnswer)
            answer = Data(buffer.readableBytesView)
        } catch {
            // AsyncHTTPClient reports a cancelled task as its own error, which would read as
            // runbloom.app being down to a caller that is only shutting down.
            if Task.isCancelled { throw CancellationError() }
            // The error's own description names the host and the failure, never a header.
            throw RunbloomError.unreachable(String(describing: error))
        }

        if success.contains(status) { return TransportResponse(status: status, body: answer, retryAfter: retryAfter) }
        if status >= 500 { throw RunbloomError.unreachable("runbloom.app answered \(status).") }
        throw Self.refusal(status: status, answer)
    }

    /// Streams are deliberately sent once. Their UUID is globally single-use, so even the usual
    /// workspace-secret refresh must become a fresh local request and a fresh UUID.
    private func sendStreamingOnce(
        _ method: HTTPMethod, _ path: String, body: Data
    ) async throws -> ModelStreamResponse {
        let request = try await request(method, path, body: body, headers: [:])
        do {
            let response = try await http.execute(request, timeout: .hours(12))
            return ModelStreamResponse(
                status: Int(response.status.code),
                contentType: response.headers.first(name: "Content-Type"),
                retryAfter: response.headers.first(name: "Retry-After"),
                body: response.body
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw RunbloomError.unreachable(String(describing: error))
        }
    }

    private func request(
        _ method: HTTPMethod, _ path: String, body: Data?, headers: [String: String],
        signsRequest: Bool = true, proof suppliedProof: MachineIdentityProofHeaders? = nil,
        usesPendingProof: Bool = false
    ) async throws -> HTTPClientRequest {
        var request = HTTPClientRequest(url: workspaceURL + path)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(secret.current)")
        request.headers.add(name: "Accept", value: "application/json")
        for (name, value) in headers { request.headers.add(name: name, value: value) }
        if signsRequest {
            let proof: MachineIdentityProofHeaders
            if let suppliedProof {
                proof = suppliedProof
            } else {
                proof = try await identity.requestHeaders(
                    method: method, path: path, body: body, usingPending: usesPendingProof
                )
            }
            for (name, value) in proof.fields { request.headers.add(name: name, value: value) }
        }
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }
        return request
    }

    /// A 4xx with runbloom.app's `code` and `message` is a refusal; one without them (a proxy's
    /// page, a bare 401) is unexpected, because there is no sentence to show a person.
    static func refusal(status: Int, _ answer: Data) -> RunbloomError {
        struct Refusal: Decodable {
            var code: String
            var message: String
            var limit: String?
            var retryAfter: Int?
            enum CodingKeys: String, CodingKey {
                case code, message, limit
                case retryAfter = "retry_after"
            }
        }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: answer) else {
            return .unexpected(status: status)
        }
        return .refused(status: status, code: refusal.code, message: refusal.message, limit: refusal.limit, retryAfter: refusal.retryAfter)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RunbloomError.unexpected(status: status)
        }
    }
}
