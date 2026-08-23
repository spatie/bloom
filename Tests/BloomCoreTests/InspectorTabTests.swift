import Foundation
import Testing
@testable import BloomCore

/// Which tabs the inspector strip offers, and what happens to a selection when one of them goes.
///
/// The whole point of the type under test is that this is answerable without a window. Nothing
/// here builds a view, and nothing here reaches for gh.
@Suite("Inspector tabs")
struct InspectorTabTests {

    private func pullRequest(checks: PullRequest.Checks, summary: String) -> PullRequest {
        PullRequest(
            number: 42,
            title: "Take the line under the greeting's button away",
            url: "https://github.com/spatie/bloom/pull/42",
            state: "OPEN",
            checks: checks,
            checksSummary: summary,
            branch: "greeting-drop-footnote"
        )
    }

    // MARK: - What is on offer

    @Test("no pull request means no Checks tab")
    func noPullRequest() {
        #expect(InspectorTab.available(for: nil) == [.allFiles, .changes])
    }

    @Test("a pull request GitHub has reported no runs for still means no Checks tab")
    func pullRequestWithoutChecks() {
        let none = pullRequest(checks: .none, summary: "No checks")
        #expect(InspectorTab.hasChecks(none) == false)
        #expect(InspectorTab.available(for: none) == [.allFiles, .changes])
    }

    @Test("any reported run brings the tab back", arguments: [
        PullRequest.Checks.pending, .passing, .failing,
    ])
    func pullRequestWithChecks(_ checks: PullRequest.Checks) {
        let open = pullRequest(checks: checks, summary: "12 checks passed")
        #expect(InspectorTab.hasChecks(open))
        #expect(InspectorTab.available(for: open) == [.allFiles, .changes, .checks])
    }

    @Test("a merged pull request keeps its checks, because they are still there to read")
    func mergedKeepsChecks() {
        var merged = pullRequest(checks: .passing, summary: "12 checks passed")
        merged.state = "MERGED"
        #expect(InspectorTab.available(for: merged).contains(.checks))
    }

    /// The tab has to arrive at the end of the strip or its arrival moves the two segments before
    /// it, which is a click landing somewhere the reader did not aim it.
    @Test("Checks is always the last segment")
    func checksIsLast() {
        let open = pullRequest(checks: .passing, summary: "1 check passed")
        #expect(InspectorTab.available(for: open).last == .checks)
        #expect(InspectorTab.available(for: open).prefix(2) == InspectorTab.available(for: nil).prefix(2))
    }

    // MARK: - What happens to the selection

    @Test("a selection that is still on offer is left alone", arguments: InspectorTab.allCases)
    func selectionSurvives(_ tab: InspectorTab) {
        let open = pullRequest(checks: .failing, summary: "1 required check failed")
        #expect(InspectorTab.resolve(tab, available: InspectorTab.available(for: open)) == tab)
    }

    @Test("Checks selected, then the pull request goes, falls back to Changes")
    func checksFallsBack() {
        #expect(InspectorTab.resolve(.checks, available: InspectorTab.available(for: nil)) == .changes)
    }

    /// The reason `resolve` takes the choice rather than clamping it: a `gh` call that fails
    /// answers "no pull request", and a reader watching CI must not be evicted by it for good.
    @Test("the choice is remembered, so the tab comes back to the reader who picked it")
    func choiceOutlivesTheGap() {
        let open = pullRequest(checks: .pending, summary: "2 checks pending")
        let chosen = InspectorTab.checks

        #expect(InspectorTab.resolve(chosen, available: InspectorTab.available(for: nil)) == .changes)
        #expect(InspectorTab.resolve(chosen, available: InspectorTab.available(for: open)) == .checks)
    }

    @Test("All files is untouched by any of this")
    func allFilesIsUnconditional() {
        #expect(InspectorTab.available(for: nil).contains(.allFiles))
        #expect(InspectorTab.resolve(.allFiles, available: InspectorTab.available(for: nil)) == .allFiles)
    }

    @Test("the fallback is one of the tabs that is always there")
    func fallbackIsAlwaysAvailable() {
        #expect(InspectorTab.available(for: nil).contains(InspectorTab.fallback))
    }
}
