import Testing
@testable import BloomCore

/// Picking a run script from the `+` menu goes back to the tab that ran it rather than starting a
/// second copy fighting over the same port.
@Suite("Run script pick")
struct RunScriptPickTests {
    private struct Tab: Sendable, Hashable {
        var name: String
        var script: String?
        var running: Bool
    }

    private func decide(_ script: String, _ tabs: [Tab]) -> RunScriptPick<Tab> {
        RunScriptPick.decide(runScript: script, tabs: tabs, scriptOf: \.script, isRunning: \.running)
    }

    @Test("no tab carries the script, so a new one opens")
    func opensWhenAbsent() {
        let tabs = [
            Tab(name: "Terminal", script: nil, running: true),
            Tab(name: "Seed", script: "seed", running: true),
        ]
        #expect(decide("vite", tabs) == .open)
        #expect(decide("vite", []) == .open)
    }

    @Test("the tab carrying the script is focused while its command runs")
    func focusesWhenRunning() {
        let vite = Tab(name: "Vite", script: "vite", running: true)
        #expect(decide("vite", [Tab(name: "Terminal", script: nil, running: true), vite]) == .focus(vite))
    }

    @Test("the tab carrying the script reruns it once its command has stopped")
    func rerunsWhenStopped() {
        let vite = Tab(name: "Vite", script: "vite", running: false)
        #expect(decide("vite", [vite]) == .rerun(vite))
    }

    @Test("a running tab wins over an earlier stopped one, and the first of each kind is taken")
    func runningWinsOverStopped() {
        let stopped = Tab(name: "Vite", script: "vite", running: false)
        let live = Tab(name: "Vite 2", script: "vite", running: true)
        let laterLive = Tab(name: "Vite 3", script: "vite", running: true)
        #expect(decide("vite", [stopped, live, laterLive]) == .focus(live))

        let laterStopped = Tab(name: "Vite 4", script: "vite", running: false)
        #expect(decide("vite", [stopped, laterStopped]) == .rerun(stopped))
    }
}
