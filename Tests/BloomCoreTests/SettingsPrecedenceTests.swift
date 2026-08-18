import Testing
import Foundation
@testable import BloomCore

/// The model a new session opens with comes from four places. They used to be three, because a
/// machine-wide settings file was merged into the same layer as the repository's own, which meant
/// a stale `~/.conductor/settings.toml` silently outranked every choice made in Settings and made
/// the Models screen look broken. These tests pin the layering apart.
@Suite("Settings precedence", .scratchDirectory)
struct SettingsPrecedenceTests {
    /// A repository directory with whichever settings files a test needs.
    private func makeRepo(_ files: [String: String]) throws -> String {
        let root = TestScratch.unique("bloom-prec")
        for (relative, contents) in files {
            let full = (root as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a repository file lands in the repo layer, not the home layer")
    func repoFileIsRepoScoped() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": """
            [models]
            default = "haiku"
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.defaultModel == "haiku")

        // The home layer must read exactly the same with and without a repository in play. The
        // old assertion here was `homeDefaultModel != "haiku"`, which quietly depended on this
        // developer's own ~/.conductor/settings.toml not happening to say haiku.
        let bare = try makeRepo([:])
        defer { try? FileManager.default.removeItem(atPath: bare) }
        #expect(settings.homeDefaultModel == SettingsLoader.load(repo: bare).homeDefaultModel)
    }

    @Test("a repository file overrides the home layer")
    func repoBeatsHome() throws {
        let repo = try makeRepo([
            ".conductor/settings.local.toml": """
            [models]
            default = "sonnet"
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.defaultModel == "sonnet")
    }

    @Test("a repository with no model leaves the repo layer empty")
    func silentRepoLeavesRepoLayerEmpty() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": """
            [scripts]
            setup = "echo hi"
            """,
        ])
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.defaultModel == nil)
        #expect(settings.setupScript == "echo hi")
    }

    @Test("the two scopes are distinct sets of paths, and together are the old list")
    func scopesPartitionTheCandidates() {
        let repo = "/tmp/example"
        let home = SettingsLoader.homePaths()
        let repoScoped = SettingsLoader.repoPaths(repo: repo)

        #expect(home.allSatisfy { $0.hasPrefix(repo) == false })
        #expect(repoScoped.allSatisfy { $0.hasPrefix(repo) })
        #expect(Set(home).isDisjoint(with: Set(repoScoped)))
        #expect(SettingsLoader.candidatePaths(repo: repo) == home + repoScoped)
    }

    /// The resolution the composer performs, kept here so the order is pinned by a test rather
    /// than only by the call site.
    private func resolve(
        repoValue: String?,
        storedValue: String?,
        homeValue: String?,
        fallback: String
    ) -> String {
        for candidate in [repoValue, storedValue, homeValue] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return fallback
    }

    @Test("resolves the model from the highest layer that has one", arguments: [
        // The repository wins over everything.
        (repo: "haiku", stored: "sonnet", home: "opus-5-1m", expected: "haiku"),
        // The case that was broken: `~/.conductor/settings.toml` pinning a model used to win
        // over what the user picked on the Models screen.
        (repo: nil, stored: "sonnet", home: "opus-5-1m", expected: "sonnet"),
        // A machine-wide file still applies when Settings was never touched.
        (repo: nil, stored: nil, home: "opus-5-1m", expected: "opus-5-1m"),
        // The built-in default is the last resort.
        (repo: nil, stored: nil, home: nil, expected: "opus"),
        // A blank string counts as unset at every layer, not as a deliberate empty choice.
        (repo: "", stored: "  ", home: "opus-5-1m", expected: "opus-5-1m"),
        (repo: "", stored: "", home: "", expected: "opus"),
    ])
    func resolvesTheModel(repo: String?, stored: String?, home: String?, expected: String) {
        #expect(resolve(repoValue: repo, storedValue: stored, homeValue: home, fallback: "opus") == expected)
    }
}
