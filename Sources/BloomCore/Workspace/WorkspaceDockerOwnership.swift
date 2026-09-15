import Foundation
import BloomClient

/// Which Docker containers, volumes and networks belong to which workspace.
///
/// **A resource belongs to a workspace when it names that workspace's id**, either in a
/// `bloom.workspace` label or inside its `com.docker.compose.project` label. Nothing else counts:
/// not a folder name, not a port, not a project that happens to have been started from inside the
/// worktree.
///
/// Three other answers were weighed and each fails somewhere this has to be right, because what
/// it decides is which databases an archive deletes.
///
/// - Recording what setup created, by listing containers before and after the script, attributes
///   a neighbouring workspace's stack to this one whenever two setups overlap, which on a server
///   creating several workspaces at once is ordinary. It also misses anything a run script or an
///   agent starts later, and it needs a column that is only as good as the last setup.
/// - Compose's `com.docker.compose.project.working_dir` label ties a container to the worktree it
///   was started from, but volumes do not carry it. Once `docker compose down` has removed the
///   containers the volumes are untraceable, and they are the part holding the data. It would
///   also hand this workspace a shared stack that merely happened to be started from its folder.
/// - Guessing from the project's own naming (`bloom-tt-...`) is a rule per project, written by
///   Bloom about projects it does not own.
///
/// A workspace id is a random UUID, so a compose project or label containing one cannot
/// belong to anything else by accident, and compose copies its project label onto every
/// container, volume and network it creates, including the volumes left behind after `down`.
/// A project opts in with one line in its scripts, which the README documents:
/// `COMPOSE_PROJECT_NAME="myapp-${BLOOM_WORKSPACE_ID//-/}"`. A project that does not opt in is
/// never touched, which is the right way round for a rule that deletes volumes.
public enum WorkspaceDockerOwnership {
    public static let workspaceLabel = "bloom.workspace"
    public static let composeProjectLabel = "com.docker.compose.project"

    /// The workspace a resource names, or nil when it names none or more than one.
    ///
    /// An explicit label wins and is not second-guessed: a resource labelled with something that
    /// is not a workspace id has said who it belongs to, and falling back to its project name
    /// would overrule it. A project naming two different ids is ambiguous and owned by neither.
    public static func workspaceID(composeProject: String?, workspaceLabel: String?) -> WorkspaceID? {
        if let label = workspaceLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return canonical(label)
        }
        guard let project = composeProject, !project.isEmpty else { return nil }
        let found = Set(ids(in: project))
        return found.count == 1 ? found.first : nil
    }

    /// A label value as the id Bloom stores: a lowercase UUID with dashes. Accepts the dashless
    /// form too, because compose project names are where people put it and many strip dashes.
    static func canonical(_ text: String) -> WorkspaceID? {
        let lowered = text.lowercased()
        let parts = lowered.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy(isHex) {
            return WorkspaceID(lowered)
        }
        if parts.count == 1, lowered.count == 32, isHex(lowered) { return dashed(lowered) }
        return nil
    }

    /// Every workspace id written into a compose project name, dashed or not.
    ///
    /// Tokenised on the separators compose allows rather than searched as a substring, so a
    /// 32 character run inside a longer hexadecimal string, a commit hash say, is not an id.
    static func ids(in project: String) -> [WorkspaceID] {
        let tokens = project.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
        var found: [WorkspaceID] = []
        for index in tokens.indices {
            let token = tokens[index]
            if token.count == 32, isHex(token), let id = dashed(token) { found.append(id) }
            if index + 4 < tokens.count {
                let window = Array(tokens[index...index + 4])
                if window.map(\.count) == [8, 4, 4, 4, 12], window.allSatisfy(isHex) {
                    found.append(WorkspaceID(window.joined(separator: "-")))
                }
            }
        }
        return found
    }

    private static func isHex(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func dashed(_ hex: String) -> WorkspaceID? {
        guard hex.count == 32 else { return nil }
        var characters = Array(hex)
        for offset in [20, 16, 12, 8] { characters.insert("-", at: offset) }
        return WorkspaceID(String(characters))
    }
}
