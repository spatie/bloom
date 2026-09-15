import Foundation
import Testing
@testable import BloomCore

/// Another process's current directory, read from the kernel. This process is the only one a test
/// can be sure of, and its directory is known by another route to compare against.
@Suite("ProcessWorkingDirectory")
struct ProcessWorkingDirectoryTests {
    /// Both sides resolved, because the kernel answers with the real path and Foundation may not:
    /// on macOS `/var` is a link to `/private/var`, and a temporary directory lives under it.
    @Test("this process's own directory is the one Foundation reports")
    func ownDirectory() throws {
        let read = try #require(ProcessWorkingDirectory.of(getpid()))
        let expected = FileManager.default.currentDirectoryPath

        #expect(read.hasPrefix("/"))
        #expect(
            URL(fileURLWithPath: read).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        )
    }

    @Test("no process id is nothing, rather than a directory guessed at", arguments: [pid_t(0), -1])
    func noProcess(_ pid: pid_t) {
        #expect(ProcessWorkingDirectory.of(pid) == nil)
    }
}
