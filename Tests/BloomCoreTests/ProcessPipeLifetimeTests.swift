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
        // StreamingProcess initialises Linux pipe-reader and dispatch infrastructure too.
        // Measuring its first use against a CapturedProcess-only baseline can count fixed
        // runtime costs as leaks. Warm the same mix, then demand a plateau across two batches.
        try await exerciseProcesses(count: 30, repository: repo.path)
        let directory = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
        let before = try descriptors(in: directory)
        for _ in 0..<2 {
            try await exerciseProcesses(count: 300, repository: repo.path)
            let after = try descriptors(in: directory)
            #expect(after.count <= before.count + 8,
                    "Descriptor count grew from \(before.count) to \(after.count). Before: \(before.kinds); after: \(after.kinds)")
        }
    }

    private func exerciseProcesses(count: Int, repository: String) async throws {
        for index in 0..<count {
            _ = try await Shell.run("/bin/echo", ["poll"])
            _ = try await Git.checkRaw(["status", "--short"], in: repository)
            if index % 10 == 0 {
                let process = StreamingProcess(executable: "/bin/echo", arguments: ["stream"])
                for try await _ in process.lines {}
            }
        }
    }

    private func descriptors(in directory: String) throws -> (count: Int, kinds: String) {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        var kinds: [String: Int] = [:]
        for name in names {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/" + name)
            let kind = target.flatMap { value in
                ["pipe:", "socket:", "anon_inode:"].first { value.hasPrefix($0) }
            } ?? "file or closed"
            kinds[kind, default: 0] += 1
        }
        return (names.count, kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
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
