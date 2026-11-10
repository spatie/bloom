import Foundation

/// Decodes both the existing prompt links and links to workspaces already in Bloom.
public enum BloomLinkRequest: Equatable, Sendable {
    case workspace(WorkspaceID, chatID: SessionID?)
    case prompt(prompt: String, path: String)

    public init(url: URL, schemes: Set<String>) throws {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
            throw Failure.unsupportedScheme
        }
        if url.host?.lowercased() == "workspace" {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.fragment == nil, parts.path.hasPrefix("/") else {
                throw Failure.invalidWorkspace
            }
            let id = String(parts.path.dropFirst())
            guard !id.isEmpty, !id.contains("/"), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalidWorkspace
            }
            let chats = (parts.queryItems ?? []).filter { $0.name == "chat" }
            guard chats.count <= 1 else { throw Failure.invalidWorkspace }
            var chatID: SessionID?
            if let chat = chats.first {
                guard let value = chat.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure.invalidWorkspace
                }
                chatID = SessionID(value)
            }
            self = .workspace(WorkspaceID(id), chatID: chatID)
            return
        }

        // Legacy links put their key/value pairs directly after ://, sometimes with a leading
        // question mark. Keep their form decoding, including + as a space, byte for byte.
        guard let separator = url.absoluteString.range(of: "://") else {
            throw Failure.missingPromptAndPath
        }
        var payload = String(url.absoluteString[separator.upperBound...])
        if payload.hasPrefix("?") { payload.removeFirst() }
        var values: [String: String] = [:]
        for pair in payload.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            values[String(pieces[0])] = String(pieces[1]).replacing("+", with: " ")
        }
        guard let prompt = values["prompt"]?.removingPercentEncoding, !prompt.isEmpty,
              let path = values["path"]?.removingPercentEncoding, !path.isEmpty else {
            throw Failure.missingPromptAndPath
        }
        self = .prompt(prompt: prompt, path: path)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unsupportedScheme
        case invalidWorkspace
        case missingPromptAndPath

        public var errorDescription: String? {
            switch self {
            case .unsupportedScheme: "This copy of Bloom does not handle the link's URL scheme."
            case .invalidWorkspace: "Use workspace/<workspace-id> with an optional ?chat=<chat-id>."
            case .missingPromptAndPath: "The link must include a prompt and project path."
            }
        }
    }
}
