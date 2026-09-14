import Testing
import Foundation
@testable import BloomCore

/// `autostart = true` can arrive by `git pull`, so a command starts on its own only once the owner
/// has approved exactly that command. These pin when the question is asked and what it says.
@Suite("Run script autostart")
struct RunScriptAutostartTests {
    private static let vite = RunScript(id: "vite", name: "Vite", command: "yarn dev", autostart: true)
    private static let horizon = RunScript(
        id: "horizon", name: "Horizon", command: "php artisan horizon", autostart: true
    )
    private static let seed = RunScript(id: "seed", name: "Seed", command: "php artisan db:seed")

    @Test("no script asking to autostart means nothing to do, approved or not")
    func nothingToAutostart() {
        #expect(RunScriptAutostart.decide(scripts: [], approval: nil) == .nothing)
        #expect(RunScriptAutostart.decide(scripts: [Self.seed], approval: nil) == .nothing)
        let missing = RunScript(id: "gone", name: "Gone", command: "", autostart: true)
        #expect(RunScriptAutostart.decide(scripts: [missing], approval: nil) == .nothing)
    }

    @Test("the signature changes when an autostart script appears or its command changes, and nothing else")
    func signatureTracksWhatWouldStart() {
        let none = RunScriptAutostart.signature(of: [Self.seed])
        let one = RunScriptAutostart.signature(of: [Self.seed, Self.vite])
        #expect(none.isEmpty)
        #expect(one != none)

        var renamed = Self.vite
        renamed.name = "Vite dev server"
        renamed.icon = "bolt"
        #expect(RunScriptAutostart.signature(of: [Self.seed, renamed]) == one)

        var changed = Self.vite
        changed.command = "yarn dev --host"
        #expect(RunScriptAutostart.signature(of: [Self.seed, changed]) != one)

        let missing = RunScript(id: "gone", name: "Gone", command: "", autostart: true)
        #expect(RunScriptAutostart.signature(of: [missing]).isEmpty)
    }

    @Test("a project that never approved anything is asked about every autostart script")
    func neverApprovedAsks() {
        let decision = RunScriptAutostart.decide(scripts: [Self.vite, Self.seed, Self.horizon], approval: nil)
        #expect(decision == .ask(scripts: [Self.vite, Self.horizon], changes: []))
    }

    @Test("approved and unchanged commands run, in order, without asking")
    func approvedRuns() {
        let approval = RunScriptAutostartApproval().approving([Self.vite, Self.horizon])
        let decision = RunScriptAutostart.decide(scripts: [Self.vite, Self.seed, Self.horizon], approval: approval)
        #expect(decision == .run([Self.vite, Self.horizon]))
    }

    @Test("a changed command asks again and names what was approved before")
    func changedCommandAsks() {
        let approval = RunScriptAutostartApproval().approving([Self.vite, Self.horizon])
        var changed = Self.vite
        changed.command = "yarn dev --host"

        let decision = RunScriptAutostart.decide(scripts: [changed, Self.horizon], approval: approval)
        #expect(decision == .ask(
            scripts: [changed, Self.horizon],
            changes: [RunScriptAutostart.Change(script: changed, approved: "yarn dev")]
        ))
    }

    @Test("a script that newly asks to autostart is a change with nothing approved before it")
    func newScriptAsks() {
        let approval = RunScriptAutostartApproval().approving([Self.vite])
        let decision = RunScriptAutostart.decide(scripts: [Self.vite, Self.horizon], approval: approval)
        #expect(decision == .ask(
            scripts: [Self.vite, Self.horizon],
            changes: [RunScriptAutostart.Change(script: Self.horizon, approved: nil)]
        ))
    }

    @Test("a script that stops autostarting needs no new approval for the rest")
    func removalDoesNotAsk() {
        let approval = RunScriptAutostartApproval().approving([Self.vite, Self.horizon])
        #expect(RunScriptAutostart.decide(scripts: [Self.vite], approval: approval) == .run([Self.vite]))
    }

    @Test("two branches with different commands are both remembered, so switching does not ask")
    func everyApprovedCommandIsKept() {
        var branch = Self.vite
        branch.command = "pnpm dev"
        let approval = RunScriptAutostartApproval().approving([Self.vite]).approving([branch])

        #expect(RunScriptAutostart.decide(scripts: [Self.vite], approval: approval) == .run([Self.vite]))
        #expect(RunScriptAutostart.decide(scripts: [branch], approval: approval) == .run([branch]))

        var third = Self.vite
        third.command = "bun dev"
        let decision = RunScriptAutostart.decide(scripts: [third], approval: approval)
        // The most recent approval is the one the question quotes.
        #expect(decision == .ask(scripts: [third], changes: [.init(script: third, approved: "pnpm dev")]))
    }

    @Test("the history per script is capped, oldest first out, and re-approving moves a command to the end")
    func historyIsCapped() {
        var approval = RunScriptAutostartApproval()
        for index in 0..<(RunScriptAutostartApproval.historyLimit + 3) {
            var script = Self.vite
            script.command = "yarn dev --port \(index)"
            approval = approval.approving([script])
        }
        let history = approval.commands["vite"] ?? []
        #expect(history.count == RunScriptAutostartApproval.historyLimit)
        #expect(history.first == "yarn dev --port 3")

        var again = Self.vite
        again.command = "yarn dev --port 5"
        #expect(approval.approving([again]).commands["vite"]?.last == "yarn dev --port 5")
        #expect(approval.approving([again]).commands["vite"]?.count == RunScriptAutostartApproval.historyLimit)
    }

    @Test("an approval is stored per project and read back", .tags(.persistence), .scratchDirectory)
    func approvalPersists() async throws {
        let store = try makeTestStore("autostart")
        let project = RepoID("project-a")
        let other = RepoID("project-b")

        #expect(await RunScriptAutostartApproval.load(repoID: project, from: store) == nil)

        let approval = RunScriptAutostartApproval().approving([Self.vite, Self.horizon])
        try await approval.save(repoID: project, to: store)

        #expect(await RunScriptAutostartApproval.load(repoID: project, from: store) == approval)
        #expect(await RunScriptAutostartApproval.load(repoID: other, from: store) == nil)
    }

    @Test("a stored approval that will not decode asks again", .tags(.persistence), .scratchDirectory)
    func unreadableApprovalAsks() async throws {
        let store = try makeTestStore("autostart")
        let project = RepoID("project-a")
        try await store.setSetting(RunScriptAutostartApproval.key(repoID: project), "not json")

        let approval = await RunScriptAutostartApproval.load(repoID: project, from: store)
        #expect(approval == nil)
        #expect(RunScriptAutostart.decide(scripts: [Self.vite], approval: approval)
            == .ask(scripts: [Self.vite], changes: []))
    }
}
