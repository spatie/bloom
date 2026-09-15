import Foundation

/// What git said when asked whether a folder is a repository, with "no" kept apart from "could
/// not ask".
///
/// `Git.isRepository` answered a Bool, and every failure of the process came back as false. A
/// user on 1.14.0 reported that every repository they tried was announced as one by Start a
/// Project and then refused by Add Project as "not a git repository". The sheet looks for a
/// `.git` on disk and the add runs `git rev-parse`, so the two disagree exactly when git itself
/// cannot run or will not work in the folder: Apple's `/usr/bin/git` with no command line tools
/// behind it exits 1 with an `xcrun: error`, and a repository owned by another account exits 128
/// with "detected dubious ownership". Both were reported as a folder that is not a repository,
/// which is untrue, names nothing to do, and on the file panel's route offered to `git init` a
/// folder that already was one.
public enum GitRepositoryAnswer: Sendable, Equatable {
    case repository
    case notARepository
    case problem(GitRepositoryProblem)
}

/// Why git could not say whether a folder is a repository.
public enum GitRepositoryProblem: Sendable, Equatable {
    /// git does not run at all: not on the PATH, or Apple's stub with no developer tools behind it.
    case gitUnusable(detail: String)
    /// The repository belongs to another user, and git refuses to work in it until it is trusted.
    case unsafeOwnership(path: String)
    /// Anything else, in git's own words.
    case failed(detail: String)
}

public extension GitRepositoryAnswer {
    /// Reads a finished `git rev-parse --is-inside-work-tree`.
    ///
    /// The markers are English, which is why `Git.repositoryAnswer` runs git with `LC_ALL=C`: a
    /// Homebrew git on a Dutch Mac says "geen git repository", and a translated "no" read as a
    /// problem would refuse every ordinary folder the sheet should have offered to track.
    static func from(status: Int32, stdout: String, stderr: String, path: String) -> GitRepositoryAnswer {
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 {
            // "false" is a `.git` directory itself, or a bare repository: git answered, and the
            // answer is that there is no work tree here.
            return output == "true" ? .repository : .notARepository
        }

        let text = stderr.isEmpty ? stdout : stderr
        if text.contains("dubious ownership") {
            return .problem(.unsafeOwnership(path: Self.ownershipPath(in: text) ?? path))
        }
        if text.contains("xcrun: error") || text.contains("developer tools")
            || text.contains("xcode-select") {
            return .problem(.gitUnusable(detail: Self.firstLine(of: text)))
        }
        if text.contains("not a git repository") { return .notARepository }
        return .problem(.failed(detail: Self.firstLine(of: text)))
    }

    /// For a process that could not be started, which is a missing git or a folder nobody can
    /// enter. Never "not a repository": nothing was asked.
    static func from(launchFailure error: Error) -> GitRepositoryAnswer {
        if let shell = error as? ShellError, shell.status == 127 {
            return .problem(.gitUnusable(detail: shell.stderr))
        }
        return .problem(.failed(detail: error.readableMessage))
    }

    var problem: GitRepositoryProblem? {
        guard case .problem(let problem) = self else { return nil }
        return problem
    }

    /// git quotes the repository it refused: `detected dubious ownership in repository at '/x'`.
    /// That is the top level, which is the path `safe.directory` wants, even when the folder
    /// handed in was somewhere inside it.
    private static func ownershipPath(in text: String) -> String? {
        guard let start = text.range(of: "repository at '") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let path = String(rest[..<end])
        return path.isEmpty ? nil : path
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "git exited without saying why"
        return String(line.prefix(300))
    }
}

public extension GitRepositoryProblem {
    /// For a person, who can act on it: each names the fix, because unlike a wrong folder none of
    /// these is fixed by picking another one.
    var sentence: String {
        switch self {
        case .gitUnusable(let detail):
            """
            Bloom could not run git, so it cannot read this folder. git said: \(detail). On a Mac \
            without Apple's command line tools, running xcode-select --install in Terminal fixes \
            this.
            """
        case .unsafeOwnership(let path):
            """
            \(path) belongs to a different user account, so git refuses to work in it. Make your \
            account the owner of the folder, or trust it by running \
            git config --global --add safe.directory '\(path)' in Terminal.
            """
        case .failed(let detail):
            "git could not read this folder. It said: \(detail)"
        }
    }

    /// For a caller with no window. The same facts, plus what `FolderRefusal.agentSentence` says
    /// to every caller: retrying will not help, and changing this machine is the owner's call.
    /// `safe.directory` especially: it is a security setting, and an agent that trusts a folder
    /// to get its own call through has made that decision for the owner.
    var agentSentence: String {
        switch self {
        case .gitUnusable(let detail):
            """
            Bloom will not add that folder as a project because git does not run on this Mac \
            (\(detail)). Retrying will not help. Tell the owner, who may need to install Apple's \
            command line tools.
            """
        case .unsafeOwnership(let path):
            """
            Bloom will not add \(path) as a project because it belongs to a different user \
            account and git refuses to work in it. Retrying will not help, and do not change git's \
            safe.directory setting yourself: trusting a folder is the owner's decision. Tell them.
            """
        case .failed(let detail):
            """
            Bloom will not add that folder as a project because git could not read it (\(detail)). \
            Retrying will not help. Tell the owner, and do not run git init to get past it.
            """
        }
    }
}
