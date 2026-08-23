import Foundation

/// Why `project_add` would not register a path, in terms a client can act on.
///
/// Built to the standard `WorkspaceStartTrouble` set, for the same reasons and against the same
/// temptations. The path is answered by asking the file system and git questions rather than by
/// catching whatever `addRepository` threw and reading its words out: `WorkspaceError` says
/// "\(path) is not a git repository", which is true of a folder that does not exist, a file, a
/// folder full of source that nobody has run `git init` in, and a volume that is not mounted, and
/// those four want four different answers. Nothing here quotes a command line, and the only paths
/// it quotes are ones the caller handed in.
///
/// The one that matters most is `notARepository`. **An agent reads "set my projects up" as
/// permission to run `git init`**, and if the refusal is a bare "not a git repository" it will
/// helpfully make one, in a folder the owner never meant to be a repository, with whatever happens
/// to be lying in it as the first commit. So that sentence says out loud that creating the
/// repository is not this tool's job and not the caller's either.
public enum ProjectAddTrouble: Sendable, Equatable {
    /// A path that means nothing on its own. Bloom's working directory is not the caller's, so a
    /// relative path resolves against something the caller cannot see.
    case notAbsolute(path: String)
    /// Nothing at that path.
    case nothingThere(path: String)
    /// Something is there and it is a file.
    case notADirectory(path: String)
    /// A folder git does not recognise.
    case notARepository(path: String)
    /// A worktree Bloom cut itself. Registering one as a project would make Bloom cut worktrees of
    /// a worktree.
    case insideBloomsWorkspaces(path: String)
    /// The home directory, or the root of the volume. Both are repositories on some machines and
    /// neither is a project.
    case tooBroad(path: String, what: String)
    /// Anything else, said plainly.
    case unexplained(String)

    public var sentence: String {
        switch self {
        case .notAbsolute(let path):
            return """
                Bloom will not add '\(path)' as a project because it is not an absolute path. \
                Bloom is a separate application and its working directory is not yours, so a \
                relative path points somewhere neither of us can agree on. Ask again with the \
                full path, starting at / or ~.
                """

        case .nothingThere(let path):
            return """
                Bloom will not add \(path) as a project because there is nothing at that path. \
                Check where the repository actually is and ask again with the right path. If you \
                were guessing, stop guessing and ask the owner.
                """

        case .notADirectory(let path):
            return """
                Bloom will not add \(path) as a project because it is a file, not a folder. A \
                project is the folder holding the repository. Ask again with the folder it is in.
                """

        case .notARepository(let path):
            return """
                Bloom will not add \(path) as a project because git does not recognise it as a \
                repository. Bloom registers repositories that already exist and it does not \
                create them, so retrying will not help and neither will running git init: \
                turning a folder into a repository is the owner's decision and not something to \
                do on their behalf while tidying up a project list. If this folder should be a \
                repository, say so and let the owner make it one.
                """

        case .insideBloomsWorkspaces(let path):
            return """
                Bloom will not add \(path) as a project because it is one of Bloom's own \
                workspaces. A workspace is a worktree Bloom already cut from a project it \
                already has, so adding it would give Bloom a project whose workspaces are \
                worktrees of a worktree. Add the repository it was cut from instead, if that is \
                not already a project.
                """

        case let .tooBroad(path, what):
            return """
                Bloom will not add \(path) as a project because it is \(what). Even where that is \
                a git repository it is not one project, and every workspace cut from it would \
                carry everything inside it. Ask again with the folder of the actual repository \
                you meant.
                """

        case .unexplained(let message):
            return "Bloom could not add that project: \(message)"
        }
    }

    /// What is wrong with this path, or nil when nothing is.
    ///
    /// The checks run in the order a person would run them: is this even a path, is anything
    /// there, is it a folder, does git know it, and only then the two locations Bloom refuses on
    /// its own account. The last two are asked of the resolved top level rather than of the path
    /// handed in, because `~/bloom/workspaces/x/src` is inside a workspace just as much as
    /// `~/bloom/workspaces/x` is, and git will happily resolve either.
    public static func diagnose(
        path: String,
        workspacesRoot: String = WorkspaceManager.workspacesRoot.path,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> ProjectAddTrouble? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .notAbsolute(path: path) }

        let standard = (expanded as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standard, isDirectory: &isDirectory) else {
            return .nothingThere(path: standard)
        }
        guard isDirectory.boolValue else { return .notADirectory(path: standard) }

        guard await Git.isRepository(standard) else { return .notARepository(path: standard) }

        let root = (try? await Git.topLevel(of: standard)) ?? standard
        if isInside(root, of: workspacesRoot) {
            return .insideBloomsWorkspaces(path: root)
        }
        if resolved(root) == resolved(home) {
            return .tooBroad(path: root, what: "your whole home folder")
        }
        if root == "/" {
            return .tooBroad(path: root, what: "the root of the volume")
        }
        return nil
    }

    /// Whether `path` is `root` or sits under it. Compared as path components rather than as a
    /// string prefix, so `~/bloom/workspaces-old` is not read as being inside `~/bloom/workspaces`.
    ///
    /// Symlinks are resolved on both sides first, and that is not tidiness. `git rev-parse
    /// --show-toplevel` answers with the resolved path, so the top level of a worktree under a
    /// symlinked workspaces root comes back pointing at the real directory and matched nothing at
    /// all against the unresolved root. On this machine `/tmp` is a symlink to `/private/tmp`,
    /// which is where the test suite works, so the check passed everywhere except where it had to
    /// hold.
    static func isInside(_ path: String, of root: String) -> Bool {
        let one = resolved(path)
        let other = resolved(root)
        return one == other || one.hasPrefix(other + "/")
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: BridgeProjectLookup.standardised(path)).resolvingSymlinksInPath().path
    }
}
