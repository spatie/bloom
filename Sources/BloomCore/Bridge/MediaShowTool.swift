import Foundation
import UniformTypeIdentifiers

public enum MediaShowToolName {
    public static let show = "media_show"
}

public enum WorkspaceMediaKind: String, Sendable, Hashable {
    case image
    case video
}

public struct WorkspaceMedia: Sendable, Hashable {
    public let url: URL
    public let relativePath: String
    public let kind: WorkspaceMediaKind

    public init(url: URL, relativePath: String, kind: WorkspaceMediaKind) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
    }

    /// Resolves a file without letting `..` or a symlink turn an inline preview into a view of a
    /// file outside the workspace. The same check runs when the tool is called and when the row is
    /// drawn, so changing a symlink after the call does not widen what the transcript may open.
    public static func resolve(path: String, in worktree: String) -> WorkspaceMedia? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !worktree.isEmpty else { return nil }

        let root = URL(filePath: worktree, directoryHint: .isDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = trimmed.hasPrefix("/")
            ? URL(filePath: trimmed)
            : root.appending(path: trimmed)
        let file = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let type = UTType(filenameExtension: file.pathExtension)
        else { return nil }

        let kind: WorkspaceMediaKind
        if type.conforms(to: .image) {
            kind = .image
        } else if type.conforms(to: .movie) {
            kind = .video
        } else {
            return nil
        }

        let relative = String(file.path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return nil }
        return WorkspaceMedia(url: file, relativePath: relative, kind: kind)
    }

    /// Resolves an image Codex has explicitly asked its host to view.
    ///
    /// Unlike the MCP media tool, Codex's native image viewer commonly points at a temporary file
    /// outside the worktree. That path came from the local Codex process rather than an MCP
    /// caller, so it may be absolute. It is still restricted to an existing image file.
    public static func resolveImageView(path: String, in worktree: String) -> WorkspaceMedia? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.hasPrefix("/"), worktree.isEmpty { return nil }
        let candidate = trimmed.hasPrefix("/")
            ? URL(filePath: trimmed)
            : URL(filePath: worktree, directoryHint: .isDirectory).appending(path: trimmed)
        let file = candidate.resolvingSymlinksInPath().standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image)
        else { return nil }

        return WorkspaceMedia(url: file, relativePath: file.lastPathComponent, kind: .image)
    }
}

public struct MediaShowOrder: Sendable, Hashable {
    public let path: String
    public let caption: String

    public init(path: String, caption: String = "") {
        self.path = path
        self.caption = caption
    }
}

public enum MediaShowOutcome: Sendable, Hashable {
    case shown(String)
    case refused(String)
}

public typealias MediaShowing = @MainActor @Sendable (
    _ order: MediaShowOrder, _ workspaceID: WorkspaceID
) async -> MediaShowOutcome

/// The part of a successful media tool call the transcript draws as content rather than as a grey
/// activity row. Exact on the bridge server name so another MCP server cannot opt itself into
/// Bloom's inline file access by also calling a tool `media_show`.
public struct MediaShowRequest: Sendable, Hashable {
    public let path: String
    public let caption: String

    public init(path: String, caption: String = "") {
        self.path = path
        self.caption = caption
    }

    public init?(use: AgentToolUse) {
        let expected = "mcp__\(BridgeRegistration.serverName)__\(MediaShowToolName.show)"
        guard use.name == expected,
              let path = use.input["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        self.path = path
        self.caption = use.input["caption"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// A native Codex `imageView` item, promoted from a grey action into visible media.
public struct CodexImageViewRequest: Sendable, Hashable {
    public let path: String

    public init?(use: AgentToolUse) {
        guard case .other(let type, _, let json)? = CodexTranslation.item(in: use.input),
              type == "imageView",
              let path = json["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        self.path = path
    }
}

public enum MediaShowRow {
    private static let probeLength = 1_024
    private static let marker = Data(
        "mcp__\(BridgeRegistration.serverName)__\(MediaShowToolName.show)".utf8
    )

    /// A cheap row-list test. Tool names occur before their inputs in both transcript envelopes,
    /// so this avoids decoding every action while still keeping a media row out of an action fold.
    public static func isCall(_ payload: Data) -> Bool {
        payload.prefix(probeLength).range(of: marker) != nil
    }
}

public enum CodexImageViewRow {
    private static let probeLength = 1_024
    private static let marker = Data("\"type\":\"imageView\"".utf8)

    /// A cheap row-list test matching the compact JSON written by `CodexTranslation`.
    public static func isCall(_ payload: Data) -> Bool {
        payload.prefix(probeLength).range(of: marker) != nil
    }
}

public struct MediaShowTool: BridgeToolHandling {
    private let show: MediaShowing

    public init(_ show: @escaping MediaShowing) { self.show = show }

    public let roles: Set<BridgeRole> = [.parent]
    public let tool = BridgeTool(
        name: MediaShowToolName.show,
        description: """
            Show a local image or video inline in this workspace's chat. Use it when visual output \
            is useful to the person, such as a screenshot, mockup, generated image, animation or \
            screen recording. The file must already exist inside this workspace. Bloom supports \
            image and movie formats macOS recognises. It does not upload or copy the file.

            'path' is workspace-relative or an absolute path inside the workspace. 'caption' is \
            optional and should be one short sentence that adds context not obvious from the media.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("The image or video file to show."),
                ]),
                "caption": .object([
                    "type": .string("string"),
                    "description": .string("An optional short caption."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    )

    public func call(
        _ request: MCPRequest, as identity: BridgeIdentity, store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure("media_show only shows a file from the workspace you are in.")
        }
        let path = request.stringParam("path")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return .failure("media_show needs a non-empty 'path'.") }
        let caption = request.stringParam("caption")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch await show(MediaShowOrder(path: path, caption: caption), workspaceID) {
        case .shown(let sentence): return BridgeToolResult(text: sentence)
        case .refused(let sentence): return .failure(sentence)
        }
    }
}
