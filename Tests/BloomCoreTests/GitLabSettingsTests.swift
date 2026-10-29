import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab settings", .scratchDirectory)
struct GitLabSettingsTests {
    @Test("a prompt with no GitLab variant is shared, override included")
    func sharedPrompts() throws {
        let defaults = try #require(UserDefaults(suiteName: "gitlab-shared-\(UUID().uuidString)"))
        let overrides = PromptOverrides(defaults: defaults)
        overrides.set("Review it my way.", for: .review)
        #expect(overrides.template(for: .review, forge: .gitLab) == "Review it my way.")
        #expect(!PromptOverrides.hasVariant(.review, for: .gitLab))
        #expect(PromptOverrides.hasVariant(.mergePullRequest, for: .gitLab))

        overrides.set("Merge with glab.", for: .mergePullRequest, forge: .gitLab)
        #expect(overrides.stored(for: .mergePullRequest) == nil)
        #expect(overrides.template(for: .mergePullRequest, forge: .gitLab) == "Merge with glab.")
    }

    @Test("the forge chosen in settings is written to the file and read back")
    func forgeRoundTrip() throws {
        let repo = TestScratch.unique("forge-roundtrip")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let settings = SettingsLoader.load(repo: repo)
        var draft = RepoSettingsDraft(settings)
        #expect(draft.forge == nil)
        draft.forge = .gitLab
        try SettingsWriter.write(draft.edits(comparedTo: settings), repo: repo, settings: settings)
        #expect(SettingsLoader.load(repo: repo).forge == .gitLab)
    }
}
