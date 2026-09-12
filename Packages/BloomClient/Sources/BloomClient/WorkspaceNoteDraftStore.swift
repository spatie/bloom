import Foundation

/// One owner per application serialises note sessions and persists their unsaved text before I/O.
@MainActor
public final class WorkspaceNoteDraftStore {
    struct Key: Codable, Hashable {
        let scope: String
        let workspaceID: WorkspaceID
    }
    struct Entry: Codable {
        let key: Key
        let text: String
        let baseline: String?
    }
    private let file: URL
    private var sessions: [Key: WorkspaceNoteSession] = [:]

    public init(file: URL) { self.file = file }

    public func session(scope: String, workspaceID: WorkspaceID) throws -> WorkspaceNoteSession {
        let key = Key(scope: scope, workspaceID: workspaceID)
        if let held = sessions[key] { return held }
        let entry = try entries().first { $0.key == key }
        let session = WorkspaceNoteSession(text: entry?.text, baseline: entry?.baseline) { [weak self] text, baseline in
            guard let self else { throw ConnectionFailure("The note draft store has closed.") }
            try self.persist(key: key, text: text, baseline: baseline)
        }
        sessions[key] = session
        return session
    }

    private func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }

    private func persist(key: Key, text: String?, baseline: String?) throws {
        var entries = try entries()
        entries.removeAll { $0.key == key }
        if let text { entries.append(Entry(key: key, text: text, baseline: baseline)) }
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
