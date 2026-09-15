import Foundation
import Testing
@testable import BloomCore

@Suite("Atomic crew creation", .tags(.persistence), .scratchDirectory)
struct AtomicCrewStartTests {
    private func fixture() async throws -> (Store, Workspace, Session) {
        let store = try makeTestStore("atomic-crew")
        let repo = try await store.upsert(Repo(name: "Fixture", path: TestScratch.unique("repo")))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Fixture", branch: "main", path: repo.path, baseBranch: "main"))
        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Orchestrator", model: "opus"))
        return (store, workspace, parent)
    }

    @Test func concurrentConnectionsCannotCreateTheSameCrewName() async throws {
        let (store, workspace, parent) = try await fixture()
        let other = try Store(path: store.path)
        let started = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<8 {
                let connection = index.isMultiple(of: 2) ? store : other
                group.addTask {
                    do {
                        _ = try await connection.startCrewMember(.init(name: "reviewer", task: "Review"), parentID: parent.id, workspaceID: workspace.id)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(started == 1)
        let members = try await store.crew(inWorkspace: workspace.id)
        #expect(members.count == 1)
        let member = try #require(members.first)
        #expect(try await store.pendingDeliveries(sessionID: member.id).count == 1)
    }

    @Test func queuedStartsReserveTheCeilingBeforeRunnersExist() async throws {
        let (store, workspace, parent) = try await fixture()
        let other = try Store(path: store.path)
        let started = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<(Crew.ceiling + 8) {
                let connection = index.isMultiple(of: 2) ? store : other
                group.addTask {
                    do {
                        _ = try await connection.startCrewMember(.init(name: "worker-\(index)", task: "Work"), parentID: parent.id, workspaceID: workspace.id)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(started == Crew.ceiling)
        let members = try await store.crew(inWorkspace: workspace.id)
        #expect(members.count == Crew.ceiling)
        #expect(members.allSatisfy { $0.state == .idle })
        let finished = try #require(members.first)
        for delivery in try await store.pendingDeliveries(sessionID: finished.id) { try await store.markDelivered(id: delivery.id) }
        let next = try await store.startCrewMember(.init(name: "replacement-slot", task: "Work"), parentID: parent.id, workspaceID: workspace.id)
        #expect(next.parentSessionID == parent.id)
    }

    @Test func freshParentWorkspaceAndNestingChecksRejectStaleCallers() async throws {
        let (store, workspace, parent) = try await fixture()
        let child = try await store.startCrewMember(.init(name: "child", task: "Work"), parentID: parent.id, workspaceID: workspace.id)
        await #expect(throws: Crew.StartRefusal.notAnOrchestrator) {
            try await store.startCrewMember(.init(name: "grandchild", task: "Work"), parentID: child.id, workspaceID: workspace.id)
        }
        await #expect(throws: Crew.StartRefusal.workspaceMismatch) {
            try await store.startCrewMember(.init(name: "wrong", task: "Work"), parentID: parent.id, workspaceID: WorkspaceID("another"))
        }
        _ = try await store.update(sessionID: parent.id) { $0.archivedAt = Date() }
        await #expect(throws: Crew.StartRefusal.parentUnavailable) {
            try await store.startCrewMember(.init(name: "after-close", task: "Work"), parentID: parent.id, workspaceID: workspace.id)
        }
        #expect(try await store.crew(inWorkspace: workspace.id).count == 1)
    }

    @Test func controlsAndStructuredBriefAreCommittedTogether() async throws {
        let (store, workspace, parent) = try await fixture()
        try await store.saveComposerControls(.init(model: "opus", effort: "high", isFastMode: true, outputStyle: "Concise"), sessionID: parent.id)
        let member = try await store.startCrewMember(.init(name: "reviewer", task: "Review this", model: "sonnet", effort: "low"), parentID: parent.id, workspaceID: workspace.id)
        #expect(member.model == "sonnet")
        #expect(member.effort == "low")
        #expect(try await store.setting(ComposerControls.fastModeKey(sessionID: member.id)) == "1")
        #expect(try await store.setting(ComposerControls.outputStyleKey(sessionID: member.id)) == "Concise")
        let delivery = try #require(try await store.pendingDeliveries(sessionID: member.id).first)
        #expect(delivery.crewMessage == .brief(from: parent.title, task: "Review this"))
    }

    @Test func aBriefInsertFailureRollsBackTheEntireCrewCreation() async throws {
        let (store, workspace, parent) = try await fixture()
        let database = try SQLiteDatabase(path: store.path)
        try database.execute("CREATE TRIGGER reject_crew_brief BEFORE INSERT ON deliveries BEGIN SELECT RAISE(ABORT, 'fixture delivery failure'); END;")
        await #expect(throws: SQLiteError.self) {
            try await store.startCrewMember(.init(name: "failed", task: "Work"), parentID: parent.id, workspaceID: workspace.id)
        }
        #expect(try await store.crew(inWorkspace: workspace.id).isEmpty)
        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [parent.id])
    }
}
