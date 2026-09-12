import Foundation
import Testing
@testable import BloomCore

@Suite("ProcessPipeLifetime", .scratchDirectory, .tags(.subprocess))
struct ProcessPipeLifetimeTests {
    /// Run in isolation because other parallel suites legitimately open descriptors too.
    @Test(.timeLimit(.minutes(2)))
    func processDescriptorsStayBounded() async throws {
        guard ProcessInfo.processInfo.environment["BLOOM_FD_STRESS"] == "1" else { return }
        let repo = try await TempRepo()
        for _ in 0..<20 {
            _ = try await Shell.run("/bin/echo", ["warmup"])
            _ = try await Git.check(["status", "--short"], in: repo.path)
        }
        let directory = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
        let before = try FileManager.default.contentsOfDirectory(atPath: directory).count
        for index in 0..<300 {
            _ = try await Shell.run("/bin/echo", ["poll"])
            _ = try await Git.checkRaw(["status", "--short"], in: repo.path)
            if index % 10 == 0 {
                let process = StreamingProcess(executable: "/bin/echo", arguments: ["stream"])
                for try await _ in process.lines {}
            }
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: directory).count
        #expect(after <= before + 8, "Descriptor count grew from \(before) to \(after)")
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentShortProcessesKeepBothStreamsUntilEOF() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<10 {
                        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "printf 'output\\n'; printf 'diagnostic\\n' >&2"], mergeStderr: false)
                        let errors = process.errorLines
                        let output = process.lines
                        let diagnostics = Task { var values: [String] = []; for await line in errors { values.append(line) }; return values }
                        var values: [String] = []
                        for try await line in output { values.append(line) }
                        #expect(values == ["output"])
                        #expect(await diagnostics.value == ["diagnostic"])
                        #expect(await process.exitStatus == 0)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
