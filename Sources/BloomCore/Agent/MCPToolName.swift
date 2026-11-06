import Foundation

/// An MCP tool's wire name, `mcp__server__tool`, taken apart into the spellings a reader needs.
///
/// This lived inside `ToolPresenter.mcp` and was private to it, which meant the live tail under a
/// running turn could not reach it. `StreamingRowView` printed the wire name straight, so a call
/// read as "Running mcp__bloom-workspace-bridge__workspace_say" for the whole of the wait and then
/// became "Bloom: workspace say" in the same slot the instant the saved row replaced it. One call,
/// two names, and the unreadable one was the one on screen while anybody was looking.
///
/// The double underscore is the separator the CLI puts between the segments, and a single
/// underscore inside a segment is a word break.
public struct MCPToolName: Equatable, Sendable {
    /// The server as the wire names it: `bloom-workspace-bridge`, `linear`.
    public let server: String

    /// The tail as the server registered it, which is what a lookup has to match.
    public let bare: String

    /// The same tail read as English. Separate from `bare` because the double underscore is a
    /// separator between segments and a word break inside one, and a single string cannot be both.
    public let tool: String

    /// Nil for anything that is not an MCP call, which is every built-in tool.
    public init?(_ name: String) {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        server = parts.first ?? name
        bare = parts.dropFirst().joined(separator: "__")
        tool = parts.dropFirst().joined(separator: " ").replacing("_", with: " ")
    }

    /// Bloom's own bridge, said as Bloom.
    ///
    /// The wire name is `bloom-workspace-bridge` and it has to stay that, which is not a
    /// convention: `BridgeRegistration.serverName` records the measurement behind it, that a Codex
    /// `-c` override deep-merges a colliding entry leaf by leaf rather than replacing it, so a
    /// server the owner had called `bloom` produced Bloom's binary running under the owner's
    /// arguments and reported itself healthy. The defence is a name nobody would type.
    ///
    /// None of which the reader should have to look at. A row reading "bloom-workspace-bridge:
    /// pane open" names the transport where every other row names the thing that happened. That is
    /// a presentation problem, so it is answered in the presentation rather than by moving the
    /// name the wire depends on.
    public var isBloom: Bool { server == BridgeRegistration.serverName }

    /// The server as a reader should meet it.
    public var displayServer: String { isBloom ? "Bloom" : server }

    /// The whole call as a reader should meet it: `mcp__linear__create_issue` is
    /// "linear: create issue".
    public var label: String {
        tool.isEmpty ? displayServer : "\(displayServer): \(tool)"
    }

    /// An individual call in an opened activity group names the operation first. Bloom's own
    /// server adds no useful context here; another server still needs its name for disambiguation.
    public var callLabel: String {
        guard !tool.isEmpty else { return "Called \(displayServer)" }
        return isBloom ? "Called \(tool)" : "Called \(label)"
    }

    public var callGlyph: String {
        if bare.hasPrefix("mail_") { return "envelope" }
        return isBloom ? "square.stack.3d.up" : "puzzlepiece.extension"
    }

    /// Any tool's name as it should be said out loud, MCP or not.
    ///
    /// A built-in is already a word (`Bash`, `Read`), so it comes back untouched. This is what the
    /// running line in the tail asks, and it asks it here rather than in the view for the reason
    /// the three-target split exists: a decision taken inside a `View` is a decision nothing can
    /// test.
    public static func readable(_ name: String) -> String {
        MCPToolName(name)?.label ?? name
    }
}
