import Testing
import Foundation
@testable import BloomCore

/// Where a CLI stands when it has no workspace.
///
/// This suite exists because the answer used to be `NSHomeDirectory()` at four call sites and
/// nothing could see it: three of them a default argument nobody reads, spending a subprocess
/// rooted at everything the user owns on every launch. Three things have to stay true of the
/// replacement: it is a folder Bloom made, there is nothing in it, and it is nowhere under `~`.
@Suite("Where an agent stands with no workspace")
struct AgentScratchDirectoryTests {
    private func temporaryBase() -> String {
        let base = NSTemporaryDirectory() + "bloom-scratch-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    @Test("it is a folder of Bloom's own, beside whatever it was given")
    func pathIsInsideTheBase() {
        #expect(AgentScratchDirectory.path(in: "/somewhere") == "/somewhere/bloom-agent-scratch")
    }

    @Test("making it leaves a real directory behind")
    func makeCreatesIt() {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let made = AgentScratchDirectory.make(in: base)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: made, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(made == AgentScratchDirectory.path(in: base))
    }

    /// The whole point. A CLI started here has nothing to find, which is what a home directory
    /// never is.
    @Test("there is nothing in it")
    func itIsEmpty() {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let made = AgentScratchDirectory.make(in: base)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: made)) ?? ["unreadable"]
        #expect(entries.isEmpty)
    }

    @Test("asking twice is the same folder rather than a second one")
    func makeIsIdempotent() {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(AgentScratchDirectory.make(in: base) == AgentScratchDirectory.make(in: base))
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        #expect(siblings == [AgentScratchDirectory.folderName])
    }

    /// The refusal that matters: a base nothing can be written into falls back to the base itself,
    /// and never to `~`. `/dev/null` is a file, so creating a folder under it cannot succeed on any
    /// Mac.
    @Test("a base it cannot write to falls back to the base, never to the home directory")
    func fallbackIsNotHome() {
        let made = AgentScratchDirectory.make(in: "/dev/null/nowhere")

        #expect(made != NSHomeDirectory())
        #expect(made == "/dev/null/nowhere")
    }

    /// The one every caller actually gets, and the property all five of them depend on. It is also
    /// outside the home directory rather than merely different from it: a CLI that walks upwards
    /// looking for configuration must not walk through `~` on the way.
    @Test("the folder this Mac uses sits outside the home directory altogether")
    func liveFolderIsOutsideHome() {
        let live = AgentScratchDirectory.current()
        let home = NSHomeDirectory()

        #expect(live != home)
        #expect(!live.hasPrefix(home + "/"))
    }

    /// `WorkspaceNamer` wrote this rule down first and applied it to itself alone. There is one
    /// answer now, and this is what says so.
    @Test("the namer stands in the same folder as everything else with no workspace")
    func namerSharesIt() {
        #expect(WorkspaceNamer.scratchDirectory == AgentScratchDirectory.current())
    }
}
