import Foundation
import Testing
@testable import BloomCore

struct ServerUpdateLifecycleTests {
    @Test("A failed install starts the stopped service without retrying installation")
    func failedInstallRestoresService() async throws {
        let calls = UpdateCalls()
        do {
            _ = try await ServerUpdateLifecycle.perform(needsStop: true,
                stop: { await calls.record("stop") },
                install: { await calls.record("install"); throw UpdateTestFailure("Upload failed") },
                restart: { await calls.record("start") })
            Issue.record("Failed install was reported as success")
        } catch let failure as ServerUpdateFailure {
            #expect(failure.serverRunning)
            #expect(!failure.installationCompleted)
            #expect(failure.primaryFailure.contains("Upload failed"))
            #expect(failure.restartFailure == nil)
        }
        #expect(await calls.values == ["stop", "install", "start"])
    }

    @Test("A lost stop acknowledgement still checks startup and preserves both failures")
    func lostStopResponseRestoresOrReportsRecoveryFailure() async throws {
        let calls = UpdateCalls()
        do {
            _ = try await ServerUpdateLifecycle.perform(needsStop: true,
                stop: { await calls.record("stop"); throw UpdateTestFailure("Stop reply lost") },
                install: { await calls.record("install"); return .init(event: "complete") },
                restart: { await calls.record("start"); throw UpdateTestFailure("SSH unavailable") })
            Issue.record("Lost stop acknowledgement was reported as success")
        } catch let failure as ServerUpdateFailure {
            #expect(!failure.serverRunning)
            #expect(!failure.installationCompleted)
            #expect(failure.primaryFailure.contains("Stop reply lost"))
            #expect(failure.restartFailure?.contains("SSH unavailable") == true)
        }
        #expect(await calls.values == ["stop", "start"])
    }

    @Test("An already stopped service is updated and verified without another stop")
    func stoppedServiceSkipsStop() async throws {
        let calls = UpdateCalls()
        let result = try await ServerUpdateLifecycle.perform(needsStop: false,
            stop: { await calls.record("stop") },
            install: { await calls.record("install"); return .init(event: "complete", message: "Installed") },
            restart: { await calls.record("start") })
        #expect(result.message == "Installed")
        #expect(await calls.values == ["install", "start"])
    }

    @Test("Cancellation after stop cannot cancel startup cleanup")
    func cancelledUpdateStillStartsService() async throws {
        let calls = UpdateCalls()
        let hold = UpdateHold()
        let task = Task {
            try await ServerUpdateLifecycle.perform(needsStop: true,
                stop: { await calls.record("stop"); await hold.wait() },
                install: { await calls.record("install"); return .init(event: "complete") },
                restart: { try Task.checkCancellation(); await calls.record("start") })
        }
        await hold.waitUntilStarted()
        task.cancel()
        await hold.release()
        do {
            _ = try await task.value
            Issue.record("Cancelled update was reported as success")
        } catch let failure as ServerUpdateFailure { #expect(failure.serverRunning) }
        #expect(await calls.values == ["stop", "start"])
    }

    @Test("A completed installation with an unconfirmed restart is not called rolled back")
    func installedButUnconfirmedRestart() async throws {
        do {
            _ = try await ServerUpdateLifecycle.perform(needsStop: false, stop: {},
                install: { .init(event: "complete") }, restart: { throw UpdateTestFailure("Not ready") })
            Issue.record("Unconfirmed startup was reported as ready")
        } catch let failure as ServerUpdateFailure {
            #expect(failure.installationCompleted)
            #expect(!failure.serverRunning)
            #expect(failure.restartFailure?.contains("Not ready") == true)
        }
    }
}

private actor UpdateCalls {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor UpdateHold {
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { held = $0; started?.resume(); started = nil } }
    func waitUntilStarted() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { held?.resume(); held = nil }
}

private struct UpdateTestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
