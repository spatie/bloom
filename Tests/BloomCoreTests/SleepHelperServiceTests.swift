import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("Sleep helper service")
struct SleepHelperServiceTests {
    private final class Fixture: Sendable {
        struct State {
            var status: SleepHelperService.Status = .notRegistered
            var registrationStatus: SleepHelperService.Status = .requiresApproval
            var failsRegistration = false
            var reads = 0
            var registrations = 0
            var usedMainThread = false
        }

        let state = Mutex(State())

        func service() -> SleepHelperService {
            SleepHelperService(
                readStatus: {
                    self.state.withLock {
                        $0.reads += 1
                        $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
                        return $0.status
                    }
                },
                register: {
                    try self.state.withLock {
                        $0.registrations += 1
                        $0.usedMainThread = $0.usedMainThread || Thread.isMainThread
                        if $0.failsRegistration { throw Failure.unsignedBuild }
                        $0.status = $0.registrationStatus
                    }
                }
            )
        }
    }

    private enum Failure: Error { case unsignedBuild }

    @Test("construction performs no synchronous service calls on the main actor")
    @MainActor func constructionDoesNotRead() {
        let fixture = Fixture()
        _ = fixture.service()
        #expect(fixture.state.withLock { $0.reads == 0 && $0.registrations == 0 })
    }

    @Test("status and registration run off the main thread even for a main actor caller")
    @MainActor func backgroundIPC() async {
        let fixture = Fixture()
        let service = fixture.service()
        let before = await service.refresh()
        let after = await service.enable()
        #expect(before == .needsApproval)
        #expect(after == .needsApproval)
        #expect(fixture.state.withLock { $0.reads == 3 && $0.registrations == 1 && !$0.usedMainThread })
    }

    @Test("refresh notices approval and revocation without registering")
    func approvalChanges() async {
        let fixture = Fixture()
        let service = fixture.service()
        fixture.state.withLock { $0.status = .enabled }
        let approved = await service.refresh()
        fixture.state.withLock { $0.status = .requiresApproval }
        let revoked = await service.refresh()
        #expect(approved == .ready)
        #expect(revoked == .needsApproval)
        #expect(fixture.state.withLock { $0.registrations == 0 })
    }

    @Test("an enabled or pending helper is not registered again", arguments: [
        SleepHelperService.Status.enabled, .requiresApproval,
    ])
    func alreadyRegistered(status: SleepHelperService.Status) async {
        let fixture = Fixture()
        fixture.state.withLock { $0.status = status }
        let service = fixture.service()
        _ = await service.enable()
        #expect(fixture.state.withLock { $0.registrations == 0 })
    }

    @Test("registration rereads status and can become ready immediately", arguments: [
        SleepHelperService.Status.notFound, .notRegistered,
    ])
    func registeredAndApproved(status: SleepHelperService.Status) async {
        let fixture = Fixture()
        fixture.state.withLock {
            $0.status = status
            $0.registrationStatus = .enabled
        }
        let service = fixture.service()
        let result = await service.enable()
        #expect(result == .ready)
        #expect(fixture.state.withLock { $0.reads == 2 && $0.registrations == 1 })
    }

    @Test("background refresh preserves a registration error until the helper becomes available")
    func registrationFailure() async {
        let fixture = Fixture()
        fixture.state.withLock { $0.failsRegistration = true }
        let service = fixture.service()
        let failed = await service.enable()
        guard case .unavailable = failed else {
            Issue.record("An unsigned helper should report a registration failure")
            return
        }
        let refreshed = await service.refresh()
        #expect(refreshed == failed)
        fixture.state.withLock { $0.status = .enabled }
        let recovered = await service.refresh()
        #expect(recovered == .ready)
    }

    @Test("concurrent enable requests register once")
    func serialRegistration() async {
        let fixture = Fixture()
        let service = fixture.service()
        await withTaskGroup(of: SleepHelperService.Standing.self) { group in
            for _ in 0 ..< 8 { group.addTask { await service.enable() } }
            for await result in group { #expect(result == .needsApproval) }
        }
        #expect(fixture.state.withLock { $0.registrations == 1 })
    }
}
