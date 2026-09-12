import Foundation
import BloomCore

/// The normal terminal view supplies its keyboard and renders bytes. HTTPS changes only the
/// transport. A reconnect reattaches tmux and never replays keystrokes from the old connection.
@MainActor
final class RemoteTerminalConnection {
    private let transport: ServerHTTPTransport
    private let workspaceID: WorkspaceID
    private let name: String
    private var socket: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    private var writes: Task<Void, Never>?
    private var columns = 80
    private var rows = 24
    private var closed = false
    private weak var view: BloomTerminalView?

    init(address: String, workspaceID: WorkspaceID, name: String, authentication: ServerAuthentication) throws {
        self.workspaceID = workspaceID; self.name = name
        transport = try ServerHTTPTransport(baseURL: ServerHTTPTransport.origin(address)) {
            try await authentication.token(for: address)
        }
    }

    func start(view: BloomTerminalView) {
        self.view = view
        pump = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        var delay = 1
        while !closed, !Task.isCancelled {
            do {
                let connected = try await transport.terminal(workspaceID: workspaceID, name: name)
                socket = connected
                try await connected.send(.string(String(decoding: JSONEncoder().encode(ServerTerminalFrame(kind: "resize", columns: columns, rows: rows)), as: UTF8.self)))
                view?.feed(text: "\u{1b}[2J\u{1b}[H")
                while !closed, !Task.isCancelled {
                    let message = try await connected.receive()
                    if case .data(let data) = message { view?.feed(byteArray: Array(data)[...]) }
                    delay = 1
                }
            } catch {
                guard !closed, !Task.isCancelled else { return }
                let status = (socket?.response as? HTTPURLResponse)?.statusCode
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                writes?.cancel(); writes = nil
                if status == 401 || status == 403 || error is ServerRefusal || error is ServerFailure {
                    view?.remoteConnectionEnded("Terminal access failed. Sign in to the server again.")
                    return
                }
                view?.feed(text: "\r\nReconnecting to the remote terminal…\r\n")
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(30, delay * 2)
            }
        }
    }

    func send(_ data: Data) {
        guard let socket, !closed else { return }
        let previous = writes
        writes = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                for offset in stride(from: 0, to: data.count, by: 16_384) {
                    try await socket.send(.data(data.subdata(in: offset..<min(data.count, offset + 16_384))))
                }
            } catch { /* The receive loop owns reconnect and its visible status. */ }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard (2...500).contains(columns), (2...300).contains(rows) else { return }
        self.columns = columns; self.rows = rows
        guard let socket, let data = try? JSONEncoder().encode(ServerTerminalFrame(kind: "resize", columns: columns, rows: rows)) else { return }
        let previous = writes
        writes = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }

    func close() {
        closed = true; writes?.cancel(); pump?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        transport.close()
    }
}
