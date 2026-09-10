import Foundation

/// One process-wide store serialises window edits. Persist before sending so an interrupted
/// submission can only be retried with its original ID, origin and exact prompt.
@MainActor
public final class ConversationDraftStore {
    public struct Scope: Hashable, Sendable {
        fileprivate let key: String
        public init(origin: String) throws { key = try RemoteOrigin.canonical(origin) }
        /// A non-secret namespace supplied by the client's existing connection identity policy.
        public init(connectionID: String) { key = "connection:" + connectionID }
    }

    public struct Draft: Codable, Equatable, Sendable {
        public var text = ""
        public fileprivate(set) var submission: RemoteCommand?
        public init() {}
    }

    private struct Entry: Codable {
        let origin: String
        let sessionID: SessionID
        var draft: Draft
    }

    private enum Storage {
        case file(URL)
        case preferences(UserDefaults, String)
    }

    private let storage: Storage
    public init(file: URL) { storage = .file(file) }
    public init(preferences: UserDefaults, key: String) { storage = .preferences(preferences, key) }

    public func draft(origin: String, sessionID: SessionID) throws -> Draft {
        try draft(scope: Scope(origin: origin), sessionID: sessionID)
    }
    public func draft(scope: Scope, sessionID: SessionID) throws -> Draft {
        try entries().first { $0.origin == scope.key && $0.sessionID == sessionID }?.draft ?? Draft()
    }

    public func save(text: String, origin: String, sessionID: SessionID) throws {
        try save(text: text, scope: Scope(origin: origin), sessionID: sessionID)
    }
    public func save(text: String, scope: Scope, sessionID: SessionID) throws {
        try update(scope: scope, sessionID: sessionID) { $0.text = text }
    }

    public func prepare(origin: String, sessionID: SessionID) throws -> RemoteCommand {
        try prepare(scope: Scope(origin: origin), sessionID: sessionID)
    }
    public func prepare(scope: Scope, sessionID: SessionID) throws -> RemoteCommand {
        var command: RemoteCommand?
        try update(scope: scope, sessionID: sessionID) { draft in
            if draft.submission == nil {
                guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectionFailure("Enter a message first.") }
                draft.submission = .send(sessionID: sessionID, text: draft.text)
            }
            command = draft.submission
        }
        guard let command else { throw ConnectionFailure("Could not save the message for sending.") }
        return command
    }

    public func submit(using client: any RemoteRequesting, origin: String, sessionID: SessionID) async throws {
        try await submit(using: client, scope: Scope(origin: origin), sessionID: sessionID)
    }
    public func submit(using client: any RemoteRequesting, scope: Scope, sessionID: SessionID) async throws {
        let command = try prepare(scope: scope, sessionID: sessionID)
        let result = try await client.request(command)
        guard result["accepted"]?.objectValue != nil else {
            throw ConnectionFailure("The server did not acknowledge this message. Your draft is saved; retry uses its original request ID.")
        }
        try acknowledge(command, scope: scope, sessionID: sessionID)
    }

    /// An acknowledgement from another window or an earlier send cannot erase newer text.
    public func acknowledge(_ command: RemoteCommand, origin: String, sessionID: SessionID) throws {
        try acknowledge(command, scope: Scope(origin: origin), sessionID: sessionID)
    }
    public func acknowledge(_ command: RemoteCommand, scope: Scope, sessionID: SessionID) throws {
        try update(scope: scope, sessionID: sessionID) { draft in
            guard draft.submission == command else { return }
            if draft.text == command.operation["send"]?["text"]?.stringValue { draft.text = "" }
            draft.submission = nil
        }
    }

    /// The caller must know which original connection owned unscoped legacy entries.
    /// Import never replaces newer scoped text or a pending submission.
    public func importLegacy(_ drafts: [String: String], scope: Scope) throws {
        var entries = try entries()
        for (id, text) in drafts where !text.isEmpty {
            let sessionID = SessionID(id)
            guard !entries.contains(where: { $0.origin == scope.key && $0.sessionID == sessionID }) else { continue }
            var draft = Draft()
            draft.text = text
            entries.append(Entry(origin: scope.key, sessionID: sessionID, draft: draft))
        }
        try persist(entries)
    }

    private func entries() throws -> [Entry] {
        let data: Data
        switch storage {
        case .file(let file):
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            data = try Data(contentsOf: file)
        case .preferences(let preferences, let key):
            guard preferences.object(forKey: key) != nil else { return [] }
            guard let value = preferences.data(forKey: key) else { throw ConnectionFailure("Saved conversation drafts could not be read.") }
            data = value
        }
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    private func update(scope: Scope, sessionID: SessionID, body: (inout Draft) throws -> Void) throws {
        var entries = try entries()
        let index = entries.firstIndex { $0.origin == scope.key && $0.sessionID == sessionID } ?? entries.endIndex
        if index == entries.endIndex { entries.append(Entry(origin: scope.key, sessionID: sessionID, draft: Draft())) }
        try body(&entries[index].draft)
        entries.removeAll { $0.draft.text.isEmpty && $0.draft.submission == nil }
        try persist(entries)
    }

    private func persist(_ entries: [Entry]) throws {
        let data = try JSONEncoder().encode(entries)
        switch storage {
        case .preferences(let preferences, let key):
            preferences.set(data, forKey: key)
        case .file(let file):
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
