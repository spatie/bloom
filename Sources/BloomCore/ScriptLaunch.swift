import Foundation

/// How one of a repository's scripts is actually started.
///
/// Bloom used to have one answer: take the string out of the settings file and hand it to
/// `zsh -c`. That made the `#!/bin/zsh` line at the top of everybody's setup script decorative,
/// which was harmless while the script only ever existed inside a TOML value and nothing else
/// could run it.
///
/// Now that scripts are real files, the shebang is a claim the file makes about itself, and the
/// honest thing is to honour it: `./.bloom/setup.sh` from a terminal and the same script started
/// by Bloom should be the same program, run by the same interpreter, or the in-app editor is
/// quietly a different environment from the one the user debugs in.
///
/// Two things stop that being unconditional. A file with no shebang cannot be executed at all
/// (the kernel answers `ENOEXEC`), and a file whose executable bit was lost, to a `git` checkout
/// on a filesystem that drops it or to somebody's `chmod`, cannot either. Both still have to run,
/// so both fall back to what has always happened.
public enum ScriptLaunch: Sendable, Hashable {
    /// Run the file itself. Its shebang chooses the interpreter.
    case executable(path: String)
    /// Run this text through `zsh -c`, which is what every script did before files existed.
    case source(String)
    /// A settings file names a script file and there is nothing at that path.
    ///
    /// Distinct from "there is no script", because they call for different behaviour: nothing to
    /// run is normal and silent, a broken pointer is worth a line in the setup log. Neither one
    /// stops a workspace being created. A missing setup script is not a reason to refuse somebody
    /// the worktree they asked for.
    case missing(path: String)

    /// What starting `script` means, given where the settings file said it lives.
    ///
    /// - Parameters:
    ///   - text: what the loader read, empty when the file it named was not there.
    ///   - file: the script file the settings named, repository-relative, or `nil` for a script
    ///     embedded in the settings file.
    ///   - repo: the repository the relative path is resolved against.
    ///
    /// Returns `nil` when this repository simply has no script of this kind.
    public static func resolve(
        text: String?, file: ScriptFile?, repo: String,
        manager: FileManager = .default
    ) -> ScriptLaunch? {
        if let file {
            let full = SettingsLoader.resolve(file.path, repo: repo)
            guard !file.isMissing, manager.fileExists(atPath: full) else {
                return .missing(path: file.path)
            }
            if manager.isExecutableFile(atPath: full), hasShebang(text ?? "") {
                return .executable(path: full)
            }
            // The file is there and readable but cannot introduce itself. Running its contents is
            // what Bloom has always done and is still exactly right.
            guard let text, !text.trimmed.isEmpty else { return nil }
            return .source(text)
        }

        guard let text, !text.trimmed.isEmpty else { return nil }
        return .source(text)
    }

    static func hasShebang(_ text: String) -> Bool {
        text.hasPrefix("#!")
    }

    /// What to spawn. `.missing` answers with a shell that does nothing, so a caller that ignores
    /// the case cannot accidentally run the path as a command.
    public var executable: String {
        switch self {
        case .executable(let path): path
        case .source, .missing: "/bin/zsh"
        }
    }

    public var arguments: [String] {
        switch self {
        case .executable: []
        case .source(let text): ["-c", text]
        case .missing: ["-c", "true"]
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
