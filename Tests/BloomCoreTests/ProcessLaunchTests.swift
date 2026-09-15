#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import BloomCore

struct ProcessLaunchTests {
    @Test func childReceivesSignalsAndSpawningThreadMaskIsRestored() throws {
        var blocked = sigset_t(), original = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGINT)
        sigaddset(&blocked, SIGTERM)
        #expect(pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0)
        defer { _ = pthread_sigmask(SIG_SETMASK, &original, nil) }

        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = ["/proc/self/status"]
        process.standardOutput = output
        try ProcessLaunch.run(process)
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let maskLine = try #require(text.split(separator: "\n").first { $0.hasPrefix("SigBlk:") })
        let mask = try #require(UInt64(maskLine.split(separator: "\t").last ?? "", radix: 16))
        #expect(mask & (1 << (SIGINT - 1)) == 0)
        #expect(mask & (1 << (SIGTERM - 1)) == 0)
        var restored = sigset_t()
        #expect(pthread_sigmask(SIG_BLOCK, nil, &restored) == 0)
        #expect(sigismember(&restored, SIGINT) == 1)
        #expect(sigismember(&restored, SIGTERM) == 1)
    }

    @Test func failedLaunchRestoresSpawningThreadMask() {
        var blocked = sigset_t(), original = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGINT)
        _ = pthread_sigmask(SIG_BLOCK, &blocked, &original)
        defer { _ = pthread_sigmask(SIG_SETMASK, &original, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bloom-test-missing-executable")
        #expect(throws: (any Error).self) { try ProcessLaunch.run(process) }
        var restored = sigset_t()
        _ = pthread_sigmask(SIG_BLOCK, nil, &restored)
        #expect(sigismember(&restored, SIGINT) == 1)
    }
}
#endif
