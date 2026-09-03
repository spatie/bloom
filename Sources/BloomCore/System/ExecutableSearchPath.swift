import Foundation

/// The directories a GUI-launched Bloom adds to the sparse PATH macOS gives it.
///
/// Package managers with one stable executable directory are named directly. Node version
/// managers are different: nvm and fnm install each Node release into its own directory and add
/// the selected release to PATH from shell startup files that Finder never reads. Walking those
/// version directories lets Bloom find a CLI installed under any of them without running a login
/// shell, whose startup files are arbitrary user code and may prompt, print or never return.
public enum ExecutableSearchPath {
    public static func additionalDirectories(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        additionalDirectories(home: home, childrenOf: directoryChildren)
    }

    static func additionalDirectories(
        home: String,
        childrenOf: (String) -> [String]
    ) -> [String] {
        let stable = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.local/bin",
            "\(home)/.npm-packages/bin",
            "\(home)/.volta/bin",
            "\(home)/.yarn/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.composer/vendor/bin",
            "\(home)/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.nodenv/shims",
            "\(home)/Library/pnpm",
            "\(home)/.local/share/pnpm",
            "\(home)/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
        ]

        let versioned = [
            (root: "\(home)/.nvm/versions/node", suffix: "bin"),
            (root: "\(home)/Library/Application Support/fnm/node-versions", suffix: "installation/bin"),
            (root: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin"),
        ].flatMap { root, suffix in
            childrenOf(root)
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/\(suffix)" }
        }

        var seen = Set<String>()
        return (stable + versioned).filter { seen.insert($0).inserted }
    }

    private static func directoryChildren(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
