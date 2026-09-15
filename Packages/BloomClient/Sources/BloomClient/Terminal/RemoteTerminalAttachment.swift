import Foundation

/// An attachment is published only after its initial size is accepted. A retired opening task
/// owns only its candidate transport, so a late failure cannot close the replacement attachment.
@MainActor
public final class RemoteTerminalAttachment {
    public typealias Open = @MainActor @Sendable () async throws -> any RemoteTerminalConnection
    public private(set) var generation = 0
    public private(set) var connection: (any RemoteTerminalConnection)?
    private var opening: Task<any RemoteTerminalConnection, Error>?
    private let open: Open
    private var desiredSize = (columns: 80, rows: 24)

    public init(open: @escaping Open) { self.open = open }

    deinit {
        let opening = opening
        opening?.cancel()
        let connection = connection
        Task {
            await connection?.close()
            if let candidate = try? await opening?.value { await candidate.close() }
        }
    }

    public func updateSize(columns: Int, rows: Int) { desiredSize = (columns, rows) }

    public func connect(columns: Int, rows: Int) async throws -> any RemoteTerminalConnection {
        try Task.checkCancellation()
        updateSize(columns: columns, rows: rows)
        if let connection { return connection }
        let generation = generation
        let task: Task<any RemoteTerminalConnection, Error>
        if let opening { task = opening } else {
            let open = open
            task = Task { [weak self] in
                let candidate = try await open()
                do {
                    try Task.checkCancellation()
                    while true {
                        let size = self?.desiredSize ?? (columns, rows)
                        try await candidate.resize(columns: size.0, rows: size.1)
                        try Task.checkCancellation()
                        guard let current = self?.desiredSize else { throw CancellationError() }
                        if size == current { break }
                    }
                    return candidate
                } catch {
                    await candidate.close()
                    throw error
                }
            }
            opening = task
        }
        let candidate: any RemoteTerminalConnection
        do { candidate = try await task.value } catch {
            guard generation == self.generation else { throw CancellationError() }
            opening = nil
            throw error
        }
        guard generation == self.generation else { await candidate.close(); throw CancellationError() }
        // A cancelled waiter does not own the shared opening task or another waiter's connection.
        try Task.checkCancellation()
        opening = nil
        connection = candidate
        return candidate
    }

    public func disconnect() {
        generation += 1
        let opening = opening
        opening?.cancel(); self.opening = nil
        let connection = connection
        self.connection = nil
        Task {
            await connection?.close()
            // Cancellation may arrive after the task returned but before a waiter published it.
            if let candidate = try? await opening?.value { await candidate.close() }
        }
    }
}
