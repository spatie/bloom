import Foundation
import Testing
@testable import BloomClient

struct ServerUpdateAvailabilityTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func aNewConnectionIsCheckedAtOnceAndThenOnlyAfterTheInterval() throws {
        var schedule = ServerUpdateCheckSchedule(interval: 6 * 3600, retryInterval: 1200)
        let first = ServerUpdateCheckSchedule.scope(serverID: "ssh:host", connectionGeneration: 1)
        #expect(schedule.isDue(scope: first, connected: true, busy: false, now: start))
        schedule.record(.checked, scope: try #require(first), at: start)
        #expect(!schedule.isDue(scope: first, connected: true, busy: false, now: start.addingTimeInterval(3600)))
        #expect(schedule.isDue(scope: first, connected: true, busy: false, now: start.addingTimeInterval(6 * 3600)))
        let reconnected = ServerUpdateCheckSchedule.scope(serverID: "ssh:host", connectionGeneration: 2)
        #expect(schedule.isDue(scope: reconnected, connected: true, busy: false, now: start.addingTimeInterval(60)))
    }

    @Test func nothingIsCheckedWhileDisconnectedBusyOrWithoutAServer() {
        let schedule = ServerUpdateCheckSchedule()
        let scope = ServerUpdateCheckSchedule.scope(serverID: "ssh:host", connectionGeneration: 1)
        #expect(!schedule.isDue(scope: scope, connected: false, busy: false, now: start))
        #expect(!schedule.isDue(scope: scope, connected: true, busy: true, now: start))
        #expect(!schedule.isDue(scope: nil, connected: true, busy: false, now: start))
        #expect(ServerUpdateCheckSchedule.scope(serverID: "", connectionGeneration: 1) == nil)
    }

    @Test func aFailedRequestRetriesSoonerThanAnAnsweredOne() throws {
        var schedule = ServerUpdateCheckSchedule(interval: 6 * 3600, retryInterval: 1200)
        let scope = try #require(ServerUpdateCheckSchedule.scope(serverID: "https://bloom.example", connectionGeneration: 3))
        schedule.record(.failed, scope: scope, at: start)
        #expect(!schedule.isDue(scope: scope, connected: true, busy: false, now: start.addingTimeInterval(600)))
        #expect(schedule.isDue(scope: scope, connected: true, busy: false, now: start.addingTimeInterval(1200)))
        schedule.record(.unavailable, scope: scope, at: start)
        #expect(!schedule.isDue(scope: scope, connected: true, busy: false, now: start.addingTimeInterval(1200)))
    }

    @Test func outcomesSeparateAnAnswerFromAFailedRequest() {
        let unauthorized = ServerMaintenanceFailure(code: "unauthorized", message: "Denied", recovery: "Add a key")
        let lost = ServerMaintenanceFailure(code: "connection_failed", message: "Lost", recovery: "Retry")
        #expect(ServerUpdateCheckSchedule.outcome(authorized: true, capability: true, failure: nil) == .checked)
        #expect(ServerUpdateCheckSchedule.outcome(authorized: false, capability: true, failure: unauthorized) == .unavailable)
        #expect(ServerUpdateCheckSchedule.outcome(authorized: false, capability: false, failure: nil) == .unavailable)
        #expect(ServerUpdateCheckSchedule.outcome(authorized: true, capability: true, failure: lost) == .failed)
        #expect(ServerUpdateCheckSchedule.outcome(authorized: false, capability: nil, failure: lost) == .failed)
    }

    @Test func noticeNeedsAccessAndStaysQuietDuringAJob() {
        let components = [server(available: "v2")]
        #expect(ServerUpdateNotice.resolve(authorized: false, capability: true, components: components, jobs: []) == nil)
        #expect(ServerUpdateNotice.resolve(authorized: true, capability: false, components: components, jobs: []) == nil)
        #expect(ServerUpdateNotice.resolve(authorized: true, capability: true, components: components,
                                           jobs: [job(.downloading, target: "v2")]) == nil)
        let notice = ServerUpdateNotice.resolve(authorized: true, capability: true, components: components, jobs: [])
        #expect(notice?.headline == "Update available")
        #expect(notice?.summary == "Bloom Server v2 is available.")
        #expect(notice?.primary?.id == .server)
    }

    @Test func upToDateUnavailableAndJustInstalledComponentsAreNotAnnounced() {
        let current = server(installed: "v2", available: "v2")
        let unknown = ServerMaintenanceComponent(id: .claude, title: "Claude Code", installedVersion: "1.0.0", canUpdate: false, detail: "")
        #expect(ServerUpdateNotice.resolve(authorized: true, capability: true, components: [current, unknown], jobs: []) == nil)
        #expect(ServerUpdateNotice.resolve(authorized: true, capability: true, components: [server(available: "v2")],
                                           jobs: [job(.succeeded, target: "v2")]) == nil)
        #expect(ServerUpdateNotice.resolve(authorized: true, capability: true, components: [server(available: "v2")],
                                           jobs: [job(.rolledBack, target: "v2")]) != nil)
    }

    @Test func incompatibleReleasesPointAtTheAdministratorUpdate() throws {
        var blocked = server(available: "v3", canUpdate: false)
        blocked.incompatible = true
        let tool = ServerMaintenanceComponent(id: .codex, title: "Codex", installedVersion: "0.1.0", availableVersion: "0.2.0",
                                              canUpdate: true, detail: "")
        let notice = try #require(ServerUpdateNotice.resolve(authorized: true, capability: true, components: [blocked, tool], jobs: []))
        #expect(notice.updates.map(\.id) == [.codex])
        #expect(notice.incompatible.map(\.id) == [.server])
        #expect(notice.primary?.id == .codex)
        #expect(notice.headline == "2 updates available")
        #expect(notice.summary.contains("Bloom Server v3 needs Update Server…"))
    }

    @Test func olderSupervisorsWithoutTheFieldStillDecode() throws {
        let legacy = Data(#"{"id":"server","title":"Bloom Server","canUpdate":true,"detail":"Ready"}"#.utf8)
        let component = try JSONDecoder().decode(ServerMaintenanceComponent.self, from: legacy)
        #expect(component.incompatible == nil)
        #expect(!component.isIncompatible)
    }

    private func server(installed: String = "v1", available: String, canUpdate: Bool = true) -> ServerMaintenanceComponent {
        .init(id: .server, title: "Bloom Server", installedVersion: installed, availableVersion: available, canUpdate: canUpdate, detail: "")
    }

    private func job(_ phase: ServerMaintenancePhase, target: String) -> ServerMaintenanceJob {
        .init(id: "j1", planID: "p1", component: .server, targetVersion: target, phase: phase,
              canCancel: false, updatedAt: "2026-09-15T10:00:00Z")
    }
}
