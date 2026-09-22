import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import Synchronization

/// A loopback-only provider-compatible front for the in-memory gateway. The random bearer is the
/// only authority accepted here. Public workspace tokens, terminal turns and cookies mean nothing.
final class ModelGatewayServer: @unchecked Sendable {
    private final class Readiness: @unchecked Sendable {
        let value = Mutex(false)
    }

    let baseURL: String
    let port: Int
    private let task: Task<Void, any Error>
    private let readiness: Readiness

    private init(port: Int, task: Task<Void, any Error>, readiness: Readiness) {
        self.port = port
        baseURL = "http://127.0.0.1:\(port)"
        self.task = task
        self.readiness = readiness
    }

    var isReady: Bool { readiness.value.withLock { $0 } }

    static func start(gateway: ModelGateway) async throws -> ModelGatewayServer {
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        var logger = Logger(label: "bloom-model-gateway")
        logger.logLevel = .critical
        let readiness = Readiness()
        let responder = CallbackResponder<BasicRequestContext> { request, _ in
            await response(to: request, gateway: gateway)
        }
        let application = Application(
            responder: responder,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "bloom-model-gateway"),
            onServerRunning: { channel in
                readiness.value.withLock { $0 = true }
                continuation.yield(channel.localAddress?.port ?? 0)
                continuation.finish()
            },
            logger: logger
        )
        let task = Task {
            defer {
                readiness.value.withLock { $0 = false }
                continuation.finish()
            }
            try await application.run()
        }
        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next(), port > 0 else {
            task.cancel()
            try await task.value
            throw ModelGateway.Refusal(status: 503, message: "The local model gateway could not listen.")
        }
        return ModelGatewayServer(port: port, task: task, readiness: readiness)
    }

    func cancel() { task.cancel() }

    func stop() async {
        task.cancel()
        _ = try? await task.value
    }

    private static func response(to request: Request, gateway: ModelGateway) async -> Response {
        guard request.method == .post else { return failure(status: 405, message: "Method not allowed.") }
        guard let token = bearer(from: request), !token.isEmpty else {
            return failure(status: 401, message: "The local model gateway credential is invalid.")
        }
        let body: Data
        do {
            body = Data(buffer: try await request.body.collect(upTo: 16 * 1_048_576))
        } catch {
            return failure(status: 422, message: "The model request is too large or malformed.")
        }

        do {
            let stream = try await gateway.open(
                token: token, path: request.uri.path, body: body,
                betas: request.headers[values: HTTPField.Name("anthropic-beta")!]
            )
            guard stream.response.status == 200 else {
                _ = try? await stream.response.body.collect(upTo: 64 * 1_024)
                await gateway.complete(token: token, requestID: stream.requestID)
                return failure(
                    status: allowed(status: stream.response.status),
                    message: message(for: stream.response.status),
                    provider: stream.provider,
                    retryAfter: stream.response.retryAfter ?? (stream.response.status == 503 ? "30" : nil)
                )
            }
            var headers = HTTPFields()
            headers[.contentType] = stream.response.contentType ?? "text/event-stream"
            headers[.cacheControl] = "no-store"
            headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                do {
                    for try await chunk in stream.response.body {
                        try await writer.write(chunk)
                    }
                    try await writer.finish(nil)
                    await gateway.complete(token: token, requestID: stream.requestID)
                } catch {
                    await gateway.cancel(token: token, requestID: stream.requestID)
                    throw error
                }
            })
        } catch let refusal as ModelGateway.Refusal {
            return failure(status: refusal.status, message: refusal.message)
        } catch is CancellationError {
            return failure(status: 499, message: "The model request was cancelled.")
        } catch {
            return failure(status: 503, message: "The model provider is unavailable.", retryAfter: "30")
        }
    }

    private static func bearer(from request: Request) -> String? {
        if let authorization = request.headers[.authorization] {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let names = [HTTPField.Name("x-api-key")!, HTTPField.Name("api-key")!]
        return names.lazy.compactMap { request.headers[$0] }.first
    }

    private static func allowed(status: Int) -> Int {
        [403, 422, 429, 503].contains(status) ? status : 503
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 403: "The model grant is no longer valid."
        case 422: "The model request was rejected."
        case 429: "Too many model requests."
        default: "The model provider is unavailable."
        }
    }

    private static func failure(
        status: Int, message: String, provider: OpaqueModelGrant.Provider? = nil,
        retryAfter: String? = nil
    ) -> Response {
        let body: [String: Any]
        if provider == .anthropic {
            body = ["type": "error", "error": ["type": "model_gateway_error", "message": message]]
        } else {
            body = ["error": ["type": "model_gateway_error", "message": message]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        if let retryAfter, status == 429 || status == 503 {
            headers[HTTPField.Name("Retry-After")!] = retryAfter
        }
        return Response(
            status: .init(code: status), headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
