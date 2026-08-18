import Testing
import Foundation
@testable import BloomCore

@Suite("Shell", .tags(.subprocess))
struct ShellTests {
    @Test("runs a command and captures stdout")
    func capturesStdout() async throws {
        let result = try await Shell.run("/bin/echo", ["hello", "world"])
        #expect(result.ok)
        #expect(result.trimmed == "hello world")
    }

    @Test("captures a non-zero exit status without throwing")
    func capturesFailure() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stderr.contains("oops"))
    }

    @Test("check throws on failure")
    func checkThrows() async throws {
        await #expect(throws: ShellError.self) {
            try await Shell.check("/bin/sh", ["-c", "exit 1"])
        }
    }

    @Test("passes stdin through")
    func passesStdin() async throws {
        let result = try await Shell.run("/bin/cat", [], stdin: "piped")
        #expect(result.trimmed == "piped")
    }

    @Test("honours the working directory")
    func honoursCwd() async throws {
        let result = try await Shell.run("/bin/pwd", [], cwd: "/tmp")
        #expect(result.trimmed.hasSuffix("tmp"))
    }

    @Test("splits output into lines")
    func splitsLines() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "printf 'a\\nb\\nc\\n'"])
        #expect(result.lines == ["a", "b", "c"])
    }

    @Test("finds executables on the augmented PATH")
    func resolvesExecutables() {
        #expect(Shell.which("git") != nil)
        #expect(Shell.which("definitely-not-a-real-binary-xyz") == nil)
    }

    @Test("captures large output without truncation")
    func capturesLargeOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "seq 1 50000"])
        #expect(result.lines.count == 50_000)
        #expect(result.lines.last == "50000")
    }
}
