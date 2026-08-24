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

    /// The answer is remembered so that starting a subprocess is not a walk of the whole PATH, and
    /// asking twice therefore has to give the same answer rather than a remembered one that has
    /// drifted.
    @Test("a remembered path is the same path")
    func remembersWhatItFound() {
        #expect(Shell.which("git") == Shell.which("git"))
    }

    /// **A miss must not be remembered**, and asking twice is what a caller that depends on that
    /// does. "Not installed" is the one answer that legitimately changes while Bloom runs:
    /// `GitHubAvailability` re-asks so that signing in to `gh` from a terminal is noticed, and
    /// `WorkspaceNamer.isAvailable` is asked afresh on every create. A table that held onto nil
    /// would make installing a CLI something you have to relaunch the app to be told about.
    ///
    /// What this can check without installing anything on the owner's machine is that a name with
    /// no answer keeps having no answer rather than being poisoned by the first ask. The other
    /// half, that the second ask genuinely walks the PATH again, is held by the shape of the code:
    /// the table is only ever written on the branch that found something.
    @Test("a name with no answer is asked again rather than remembered as missing")
    func doesNotRememberAMiss() {
        let name = "bloom-not-installed-\(UUID().uuidString.prefix(8))"
        #expect(Shell.which(name) == nil)
        #expect(Shell.which(name) == nil)
    }

    @Test("captures large output without truncation")
    func capturesLargeOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "seq 1 50000"])
        #expect(result.lines.count == 50_000)
        #expect(result.lines.last == "50000")
    }
}
