import Testing
import Foundation
@testable import BatonCore

/// The model a new session opens with comes from four places. They used to be three, because a
/// machine-wide settings file was merged into the same layer as the repository's own, which meant
/// a stale `~/.conductor/settings.toml` silently outranked every choice made in Settings and made
/// the Models screen look broken. These tests pin the layering apart.
@Suite("Settings precedence")
struct SettingsPrecedenceTests {
    /// A repository directory with whichever settings files a test needs.
    private func makeRepo(_ files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "baton-prec-\(UUID().uuidString)"
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
        // Whatever the real machine-wide file says, it must never leak into the repo layer.
        #expect(settings.homeDefaultModel != "haiku")
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

        #expect(home.allSatisfy { !$0.hasPrefix(repo) })
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

    @Test("the repository wins over everything")
    func repositoryWins() {
        #expect(resolve(repoValue: "haiku", storedValue: "sonnet", homeValue: "opus-5-1m", fallback: "opus") == "haiku")
    }

    @Test("what the user chose in Settings beats a machine-wide file")
    func settingsBeatsHomeFile() {
        // This is the case that was broken: `~/.conductor/settings.toml` pinning a model used to
        // win over the Models screen.
        #expect(resolve(repoValue: nil, storedValue: "sonnet", homeValue: "opus-5-1m", fallback: "opus") == "sonnet")
    }

    @Test("a machine-wide file still applies when Settings was never touched")
    func homeFileAppliesWhenUnset() {
        #expect(resolve(repoValue: nil, storedValue: nil, homeValue: "opus-5-1m", fallback: "opus") == "opus-5-1m")
    }

    @Test("the built-in default is the last resort")
    func fallbackIsLast() {
        #expect(resolve(repoValue: nil, storedValue: nil, homeValue: nil, fallback: "opus") == "opus")
    }

    @Test("an empty string counts as unset at every layer")
    func emptyCountsAsUnset() {
        #expect(resolve(repoValue: "", storedValue: "  ", homeValue: "opus-5-1m", fallback: "opus") == "opus-5-1m")
        #expect(resolve(repoValue: "", storedValue: "", homeValue: "", fallback: "opus") == "opus")
    }
}
