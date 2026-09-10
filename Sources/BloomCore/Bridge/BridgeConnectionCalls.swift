import Foundation

/// Reading the socket continues while a tool awaits a UI result. MCP cancellation and connection
/// closure can therefore cancel that call instead of waiting behind the call they must stop.
actor BridgeConnectionCalls {
    private var running: [JSONValue: Task<Void, Never>] = [:]
    private var finished: [JSONValue: String] = [:]
    private var order: [JSONValue] = []
    private var finishedBytes = 0
    private var closed = false
    private var tail: Task<Void, Never>?

    func receive(_ line: String, dispatch: BridgeDispatch, connection: UnixSocketConnection) async {
        guard !closed, let request = MCPRequest.decode(line) else { return }
        if request.method == "notifications/cancelled", let id = request.param("requestId") {
            running[id]?.cancel()
            return
        }
        guard let id = request.replyID else { return }
        if let reply = finished[id] { await connection.writeLineAsync(reply); return }
        guard running[id] == nil else { return }
        guard running.count < 32 else {
            await connection.writeLineAsync(MCPResponse.failure(id: id, code: MCPErrorCode.invalidParams, message: "Too many bridge requests are pending.").line())
            return
        }
        let previous = tail
        let task = Task { [weak self] in
            // Keep the existing per-connection mutation order while the socket reader remains
            // free to receive cancellation. Crew and workspace start policy relies on this order.
            await previous?.value
            let response: MCPResponse?
            if Task.isCancelled {
                response = .result(id: id, BridgeToolResult.failure("The bridge call was cancelled.").content)
            } else {
                response = await dispatch.respond(to: request)
            }
            await self?.complete(id, response: response, connection: connection)
        }
        running[id] = task
        tail = task
    }

    private func complete(_ id: JSONValue, response: MCPResponse?, connection: UnixSocketConnection) async {
        defer { running[id] = nil }
        guard !closed, let reply = response?.line() else { return }
        finished[id] = reply; order.append(id); finishedBytes += reply.utf8.count
        while order.count > 128 || finishedBytes > 8 * 1_024 * 1_024 {
            if let removed = finished.removeValue(forKey: order.removeFirst()) { finishedBytes -= removed.utf8.count }
        }
        await connection.writeLineAsync(reply)
    }

    func close() async {
        closed = true
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        running = [:]; finished = [:]; order = []; tail = nil; finishedBytes = 0
        for task in tasks { await task.value }
    }
}
