import Foundation
import BloomClient

public typealias ServerTerminalFrame = BloomClient.RemoteTerminalFrame

/// Control mode provides terminal bytes without giving the gateway permission to spawn an agent
/// or read its credentials. Disconnect terminates only the tmux client; its shell stays running.
actor ServerTerminalStreams {
    private struct Entry {
        var listener: UnixSocketListener
        var terminal: ServerTerminal
        var workspace: Workspace
        var connection: UnixSocketConnection?
        var process: StreamingProcess?
    }
    private var entries: [UUID: Entry] = [:]
    private let groupID: UInt32?
    private let makeProcess: @Sendable (ServerTerminal, Workspace) -> StreamingProcess
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var expirations: [UUID: Task<Void, Never>] = [:]
    private var terminations: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    init(groupID: UInt32?, makeProcess: (@Sendable (ServerTerminal, Workspace) -> StreamingProcess)? = nil) {
        self.groupID = groupID
        self.makeProcess = makeProcess ?? { terminal, workspace in
            StreamingProcess(executable: terminal.executable,
                arguments: ["-S", terminal.socket, "-C", "attach-session", "-t", "=" + terminal.session],
                cwd: workspace.path, environment: Shell.environment(extra: ["TERM": "xterm-256color"]))
        }
    }

    func open(terminal: ServerTerminal, workspace: Workspace) throws -> String {
        guard !closed else { throw ServerFailure("The server terminal connection is shutting down.") }
        guard entries.count < 32 else { throw ServerFailure("Too many terminal connections are open.") }
        let id = UUID()
        let path = "/tmp/bloom-terminal-\(id.uuidString).sock"
        let listener = try UnixSocketListener(path: path, groupID: groupID) { [weak self] connection in
            Task { await self?.attach(id, connection: connection) }
        }
        entries[id] = Entry(listener: listener, terminal: terminal, workspace: workspace)
        expirations[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                await self?.expire(id)
            } catch { /* Closing or attaching cancels the unused-listener deadline. */ }
            await self?.expired(id)
        }
        return path
    }

    private func expire(_ id: UUID) {
        guard entries[id]?.connection == nil else { return }
        close(id)
    }

    private func expired(_ id: UUID) { expirations[id] = nil }

    private func attach(_ id: UUID, connection: UnixSocketConnection) {
        guard !closed, var entry = entries[id], entry.connection == nil else { connection.close(); return }
        entry.listener.stop()
        expirations[id]?.cancel()
        entry.connection = connection
        let terminal = entry.terminal
        let process = makeProcess(terminal, entry.workspace)
        entry.process = process
        let lines = process.lines
        process.writeLine("refresh-client -C 80,24")
        process.writeLine("capture-pane -p -e -t =" + terminal.session + ":")
        process.writeLine("display-message -p -t =" + terminal.session + ": '#{cursor_x} #{cursor_y}'")
        workers[id] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var decoder = TmuxControlOutput(restoringScreen: true)
                    do {
                        for try await line in lines {
                            guard !Task.isCancelled else { break }
                            if let data = decoder.take(line), let frame = try? JSONEncoder().encode(ServerTerminalFrame(kind: "output", data: data)) {
                                await connection.writeLineAsync(String(decoding: frame, as: UTF8.self))
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
            await self?.finished(id)
        }
        entries[id] = entry
    }

    private func close(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.listener.stop(); entry.connection?.close(); entry.process?.terminate()
        expirations[id]?.cancel()
        workers[id]?.cancel()
        if let process = entry.process {
            terminations[id] = ServerTerminalProcessLifetime.stop(process)
        }
    }

    private func finished(_ id: UUID) async {
        if let ending = terminations[id] { await ending.value }
        workers[id] = nil
        terminations[id] = nil
    }

    func shutdown() async {
        closed = true
        let pending = Array(workers.values) + Array(expirations.values)
        for id in Array(entries.keys) { close(id) }
        for task in pending { await task.value }
    }
    func close(workspaceID: WorkspaceID) {
        for (id, entry) in entries where entry.workspace.id == workspaceID { close(id) }
    }
}

struct TmuxControlOutput {
    private var block: String?
    // The initial replies are attach, resize, screen capture and cursor position, in order.
    private var blockNumber = -1
    private var captured: [String] = []
    private let restoringScreen: Bool

    init(restoringScreen: Bool = false) { self.restoringScreen = restoringScreen }

    mutating func take(_ line: String) -> Data? {
        if let block {
            if line == "%end " + block || line == "%error " + block {
                self.block = nil
                defer { captured.removeAll() }
                guard restoringScreen, line.hasPrefix("%end ") else { return nil }
                if blockNumber == 2 { return Data(("\u{1b}[2J\u{1b}[H" + captured.joined(separator: "\r\n")).utf8) }
                if blockNumber == 3, let position = captured.first {
                    let values = position.split(separator: " ").compactMap { Int($0) }
                    guard values.count == 2, values.allSatisfy({ (0..<10_000).contains($0) }) else { return nil }
                    return Data("\u{1b}[\(values[1] + 1);\(values[0] + 1)H".utf8)
                }
                return nil
            }
            if restoringScreen, blockNumber <= 3 { captured.append(line); return nil }
            return Data((line + "\r\n").utf8)
        }
        if line.hasPrefix("%begin ") { block = String(line.dropFirst(7)); blockNumber += 1; return nil }
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
