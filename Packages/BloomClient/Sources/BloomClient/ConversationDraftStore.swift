import Foundation

/// One process-wide store serialises window edits. Persist before sending so an interrupted
/// submission can only be retried with its original ID, origin and exact prompt.
@MainActor
public final class ConversationDraftStore {
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

    private let file: URL
    public init(file: URL) { self.file = file }

    public func draft(origin: String, sessionID: SessionID) throws -> Draft {
        let origin = try canonicalOrigin(origin)
        return try entries().first { $0.origin == origin && $0.sessionID == sessionID }?.draft ?? Draft()
    }

    public func save(text: String, origin: String, sessionID: SessionID) throws {
        try update(origin: origin, sessionID: sessionID) { $0.text = text }
    }

    public func prepare(origin: String, sessionID: SessionID) throws -> RemoteCommand {
        var command: RemoteCommand?
        try update(origin: origin, sessionID: sessionID) { draft in
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
        let command = try prepare(origin: origin, sessionID: sessionID)
        let result = try await client.request(command)
        guard result["accepted"]?.objectValue != nil else {
            throw ConnectionFailure("The server did not acknowledge this message. Your draft is saved; retry uses its original request ID.")
        }
        try acknowledge(command, origin: origin, sessionID: sessionID)
    }

    /// An acknowledgement from another window or an earlier send cannot erase newer text.
    public func acknowledge(_ command: RemoteCommand, origin: String, sessionID: SessionID) throws {
        try update(origin: origin, sessionID: sessionID) { draft in
            guard draft.submission == command else { return }
            if draft.text == command.operation["send"]?["text"]?.stringValue { draft.text = "" }
            draft.submission = nil
        }
    }

    private func canonicalOrigin(_ text: String) throws -> String {
        if var ssh = URLComponents(string: text), ssh.scheme?.lowercased() == "ssh" {
            guard let host = ssh.host, !host.isEmpty, let user = ssh.user, !user.isEmpty,
                  ssh.password == nil, ssh.query == nil, ssh.fragment == nil, ssh.path.hasPrefix("/") else {
                throw ConnectionFailure("Enter a valid SSH server address and data directory.")
            }
            ssh.scheme = "ssh"; ssh.host = host.lowercased()
            if ssh.port == 22 { ssh.port = nil }
            guard let identity = ssh.string else { throw ConnectionFailure("Invalid SSH server address.") }
            return identity
        }
        let url = try HTTPSConnection.origin(text)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionFailure("Enter a valid HTTPS server address.")
        }
        if components.port == 443 { components.port = nil }
        guard let origin = components.url else { throw ConnectionFailure("Enter a valid HTTPS server address.") }
        return origin.absoluteString
    }

    private func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }

    private func update(origin: String, sessionID: SessionID, body: (inout Draft) throws -> Void) throws {
        let origin = try canonicalOrigin(origin)
        var entries = try entries()
        let index = entries.firstIndex { $0.origin == origin && $0.sessionID == sessionID } ?? entries.endIndex
        if index == entries.endIndex { entries.append(Entry(origin: origin, sessionID: sessionID, draft: Draft())) }
        try body(&entries[index].draft)
        entries.removeAll { $0.draft.text.isEmpty && $0.draft.submission == nil }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entries)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
