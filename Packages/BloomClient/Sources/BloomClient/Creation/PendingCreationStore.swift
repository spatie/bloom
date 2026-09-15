import Foundation

/// Persist the exact request before transport. An uncertain create is never reconstructed from edited fields.
@MainActor
public final class PendingCreationStore {
    private struct Entry: Codable { let origin: String; let scope: String; let command: RemoteCommand }
    private let file: URL
    public init(file: URL) { self.file = file }

    public func pending(origin: String, scope: String) throws -> RemoteCommand? {
        let origin = try RemoteOrigin.canonical(origin)
        return try entries().first { $0.origin == origin && $0.scope == scope }?.command
    }

    public func prepare(_ command: RemoteCommand, origin: String, scope: String) throws -> RemoteCommand {
        let origin = try RemoteOrigin.canonical(origin)
        var values = try entries()
        if let existing = values.first(where: { $0.origin == origin && $0.scope == scope }) { return existing.command }
        values.append(Entry(origin: origin, scope: scope, command: command))
        try write(values)
        return command
    }

    public func acknowledge(_ command: RemoteCommand, origin: String, scope: String) throws {
        let origin = try RemoteOrigin.canonical(origin)
        try write(entries().filter { !($0.origin == origin && $0.scope == scope && $0.command == command) })
    }

    /// This forgets a retry, never a workspace. The caller must explain that the server may have created it.
    public func discard(origin: String, scope: String) throws {
        let origin = try RemoteOrigin.canonical(origin)
        try write(entries().filter { !($0.origin == origin && $0.scope == scope) })
    }

    private func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 4_194_304 else { throw ConnectionFailure("The saved creation requests are too large to read safely.") }
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        guard data.count <= 4_194_304 else { throw ConnectionFailure("Too many creation requests are waiting for confirmation.") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
