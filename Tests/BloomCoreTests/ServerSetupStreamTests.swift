import Foundation
import Testing
@testable import BloomCore

@Suite("Live setup diagnostics", .scratchDirectory, .tags(.subprocess))
struct ServerSetupStreamTests {
    @Test func stderrIsDeliveredBeforeExitAndStructuredFailureKeepsItsExplanation() async throws {
        let release = TestScratch.unique("setup-output-received")
        let source = """
        printf '%s\\n' '{"event":"progress","step":"dependencies","message":"Installing packages"}'
        printf '%s\\n' 'apt-get: a package could not be found TOKEN=hide-me' >&2
        while [ ! -e '\(release)' ]; do sleep 0.01; done
        printf '%s\\n' 'An ordinary stdout diagnostic'
        printf '%s\\n' '{"event":"error","code":"dependency_failed","message":"Package installation failed","recovery":"Check the configured package mirrors","command":"apt-get install","exitStatus":42,"details":"Package example is unavailable"}'
        exit 42
        """
        let observed = SetupEvents()
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", source], mergeStderr: false)
        do {
            _ = try await ServerSetupStream.run(process, input: "", timeout: .seconds(5), progress: { event in
                await observed.append(event)
                if event.message?.contains("a package could not be found") == true { try? Data().write(to: URL(fileURLWithPath: release)) }
            })
            Issue.record("A failed installer was accepted")
        } catch let failure as ServerSetupFailure {
            #expect(failure.code == .installation)
            #expect(failure.message == "Package installation failed")
            #expect(failure.recovery == "Check the configured package mirrors")
            #expect(failure.command == "apt-get install" && failure.exitStatus == 42)
            #expect(failure.details == "Package example is unavailable")
        }
        let events = await observed.events
        #expect(events.contains { $0.event == "progress" && $0.step == "dependencies" })
        #expect(events.contains { $0.message == "An ordinary stdout diagnostic" })
        #expect(!events.contains { $0.message?.contains("hide-me") == true })
    }

    @Test func uploadOutputIsLivePlainTextAndDoesNotForgeInstallerCompletion() async throws {
        let observed = SetupEvents()
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' '{\"event\":\"complete\"}'; printf 'upload warning\\n' >&2"], mergeStderr: false)
        _ = try await ServerSetupStream.run(process, input: "", requiresCompletion: false, commandLabel: "scp", step: "upload-package", progress: { await observed.append($0) })
        let events = await observed.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.event == "output" && $0.step == "upload-package" })
        #expect(events.contains { $0.message == "upload warning" })
    }

    @Test func nonJSONFailureIncludesItsLastDiagnosticAndExitStatus() async throws {
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "printf 'dpkg could not open /var/lib/dpkg/lock\\n' >&2; exit 7"], mergeStderr: false)
        do {
            _ = try await ServerSetupStream.run(process, input: "", progress: { _ in })
            Issue.record("A non-JSON failure was accepted")
        } catch let failure as ServerSetupFailure {
            #expect(failure.details == "dpkg could not open /var/lib/dpkg/lock")
            #expect(failure.command == "ssh" && failure.exitStatus == 7)
        }
    }

    @Test func timeoutIsDistinctAndTerminatesAProcessThatIgnoresSIGTERM() async throws {
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"], mergeStderr: false)
        do {
            _ = try await ServerSetupStream.run(process, input: "", timeout: .milliseconds(200), killDelay: .milliseconds(100), progress: { _ in })
            Issue.record("A stalled installer was accepted")
        } catch let failure as ServerSetupFailure { #expect(failure.code == .timedOut) }
        #expect(!process.isRunning)
    }

    @Test func cancellationWinsEvenIfACompletionEventAlreadyArrived() async throws {
        let ready = SetupReady()
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' '{\"event\":\"complete\",\"ready\":true}'; sleep 30"], mergeStderr: false)
        let running = Task {
            try await ServerSetupStream.run(process, input: "", killDelay: .milliseconds(100), progress: { event in
                if event.event == "complete" { await ready.signal() }
            })
        }
        await ready.wait()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!process.isRunning)
    }
}

private actor SetupEvents {
    private(set) var events: [ServerInstallEvent] = []
    func append(_ event: ServerInstallEvent) { events.append(event) }
}
private actor SetupReady {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async { if !signalled { await withCheckedContinuation { waiter = $0 } } }
}
