import Foundation
import Testing
@testable import BloomCore

@Suite("Shell capture", .tags(.subprocess))
struct ShellCaptureTests {
    @Test("deadline includes inherited pipes after parent exit")
    func inheritedPipe() async throws {
        await #expect(throws: ShellFailure.timedOut(command: "/bin/sh")) {
            try await Shell.run("/bin/sh", ["-c", "(sleep 2) & exit 0"], timeout: .milliseconds(100))
        }
    }

    @Test("a child ignoring TERM cannot defeat the deadline")
    func ignoresTermination() async throws {
        await #expect(throws: ShellFailure.timedOut(command: "/bin/sh")) {
            try await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 2"], timeout: .milliseconds(100))
        }
    }

    @Test("deadline also covers writing input that the child does not read")
    func blockedInput() async throws {
        await #expect(throws: ShellFailure.timedOut(command: "/bin/sh")) {
            try await Shell.run(
                "/bin/sh", ["-c", "sleep 2"], stdin: String(repeating: "x", count: 1_000_000),
                timeout: .milliseconds(100)
            )
        }
    }

    @Test("oversized structured output fails instead of returning a partial success")
    func outputBudget() async throws {
        await #expect(throws: ShellFailure.outputLimit(command: "/usr/bin/yes", stream: "stdout", limit: 128)) {
            try await Shell.run("/usr/bin/yes", timeout: .seconds(2), outputLimit: 128)
        }
    }

    @Test("raw bytes and the final flush survive collection")
    func bytesAndFlush() async throws {
        let result = try await Shell.runBytes("/bin/sh", ["-c", "printf '\\377\\000end'; printf err >&2"])
        #expect(result.status == 0)
        #expect(result.stdout == Data([255, 0, 101, 110, 100]))
        #expect(result.stderr == Data("err".utf8))
    }

    @Test("large input can be read and echoed without a pipe deadlock")
    func fullDuplex() async throws {
        let input = Data(repeating: 120, count: 1_000_000)
        let result = try await Shell.runBytes("/bin/cat", stdin: input, timeout: .seconds(5))
        #expect(result.stdout == input)
        #expect(result.status == 0)
    }

    @Test("a cancelled invocation reports cancellation")
    func cancellation() async throws {
        let task = Task { try await Shell.run("/bin/sh", ["-c", "sleep 2"], timeout: .seconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
