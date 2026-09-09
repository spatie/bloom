import Foundation

public struct ServerTerminalFrame: Codable, Sendable {
    public var kind: String
    public var data: Data?
    public var columns: Int?
    public var rows: Int?

    public init(kind: String, data: Data? = nil, columns: Int? = nil, rows: Int? = nil) {
        self.kind = kind; self.data = data; self.columns = columns; self.rows = rows
    }
}

/// Control mode provides terminal bytes without giving the gateway permission to spawn an agent
/// or read its credentials. Disconnect terminates only the tmux client; its shell stays running.
actor ServerTerminalStreams {
    private struct Entry {
        var listener: UnixSocketListener
        var terminal: ServerTerminal
        var workspace: Workspace
        var connection: UnixSocketConnection?
        var process: StreamingProcess?
        var task: Task<Void, Never>?
    }
    private var entries: [UUID: Entry] = [:]
    private let groupID: UInt32?

    init(groupID: UInt32?) { self.groupID = groupID }

    func open(terminal: ServerTerminal, workspace: Workspace) throws -> String {
        guard entries.count < 32 else { throw ServerFailure("Too many terminal connections are open.") }
        let id = UUID()
        let path = "/tmp/bloom-terminal-\(id.uuidString).sock"
        let listener = try UnixSocketListener(path: path, groupID: groupID) { [weak self] connection in
            Task { await self?.attach(id, connection: connection) }
        }
        entries[id] = Entry(listener: listener, terminal: terminal, workspace: workspace)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.expire(id)
        }
        return path
    }

    private func expire(_ id: UUID) {
        guard entries[id]?.connection == nil else { return }
        close(id)
    }

    private func attach(_ id: UUID, connection: UnixSocketConnection) {
        guard var entry = entries[id], entry.connection == nil else { connection.close(); return }
        entry.listener.stop()
        entry.connection = connection
        let terminal = entry.terminal
        let process = StreamingProcess(executable: terminal.executable,
            arguments: ["-S", terminal.socket, "-C", "attach-session", "-t", "=" + terminal.session],
            cwd: entry.workspace.path, environment: Shell.environment(extra: ["TERM": "xterm-256color"]))
        entry.process = process
        let lines = process.lines
        process.writeLine("refresh-client -C 80,24")
        process.writeLine("capture-pane -p -e -t =" + terminal.session + ":")
        entry.task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var decoder = TmuxControlOutput()
                    do {
                        for try await line in lines {
                            guard !Task.isCancelled else { break }
                            if let data = decoder.take(line), let frame = try? JSONEncoder().encode(ServerTerminalFrame(kind: "output", data: data)) {
                                connection.writeLine(String(decoding: frame, as: UTF8.self))
                            }
                        }
                    } catch { /* Closing the socket reports a terminated terminal client. */ }
                }
                group.addTask {
                    for await line in connection.lines {
                        guard !Task.isCancelled, line.utf8.count <= 100_000,
                              let frame = try? JSONDecoder().decode(ServerTerminalFrame.self, from: Data(line.utf8)),
                              let command = TmuxControlOutput.command(frame, session: terminal.session) else { break }
                        process.writeLine(command)
                    }
                }
                await group.next()
                group.cancelAll()
                process.terminate()
                connection.close()
            }
            await self?.close(id)
        }
        entries[id] = entry
    }

    private func close(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.listener.stop(); entry.connection?.close(); entry.process?.terminate(); entry.task?.cancel()
    }

    func shutdown() { for id in Array(entries.keys) { close(id) } }
    func close(workspaceID: WorkspaceID) {
        for (id, entry) in entries where entry.workspace.id == workspaceID { close(id) }
    }
}

struct TmuxControlOutput {
    private var block: String?

    mutating func take(_ line: String) -> Data? {
        if let block {
            if line == "%end " + block || line == "%error " + block { self.block = nil; return nil }
            return Data((line + "\r\n").utf8)
        }
        if line.hasPrefix("%begin ") { block = String(line.dropFirst(7)); return nil }
        guard line.hasPrefix("%output "), let separator = line.dropFirst(8).firstIndex(of: " ") else { return nil }
        let bytes = Array(line[line.index(after: separator)...].utf8)
        var output = Data(); var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 3 < bytes.count, bytes[(index + 1)...(index + 3)].allSatisfy({ (48...55).contains($0) }) {
                let value = Int(bytes[index + 1] - 48) * 64 + Int(bytes[index + 2] - 48) * 8 + Int(bytes[index + 3] - 48)
                guard value <= 255 else { return nil }
                output.append(UInt8(value)); index += 4
            } else { output.append(bytes[index]); index += 1 }
        }
        return output
    }

    static func command(_ frame: ServerTerminalFrame, session: String) -> String? {
        switch frame.kind {
        case "input":
            guard let data = frame.data, !data.isEmpty, data.count <= 16_384 else { return nil }
            return "send-keys -H -t =" + session + ": " + data.map { String(format: "%02x", $0) }.joined(separator: " ")
        case "resize":
            guard let columns = frame.columns, let rows = frame.rows, (2...500).contains(columns), (2...300).contains(rows) else { return nil }
            return "refresh-client -C \(columns),\(rows)"
        default: return nil
        }
    }
}
