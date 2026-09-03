import Testing
import Foundation
@testable import BloomCore

/// The rule that decides where new worktrees are cut, which is the one decision in Bloom that can
/// silently split one project's checkouts across two folders. Every case here is an installation:
/// one that has never run, one that has been running for months, one that has just cut its first
/// worktree, and the odd shapes a home directory can be in.
///
/// Every test that touches a disk builds its own home directory under the scratch folder. Nothing
/// here may look at, let alone create, the real `~/bloom`.
@Suite("Where new worktrees are cut", .scratchDirectory)
struct WorkspacesRootTests {
    /// `resolve(home:exists:)` with a set of paths that are there, which is the whole rule with no
    /// file system in it.
    private func resolve(home: String, present: Set<String>) -> String {
        WorkspacesRoot.resolve(home: URL(fileURLWithPath: home)) {
            present.contains($0.path)
        }.path
    }

    @Test("a machine that has never run Bloom gets the folder Spotlight skips")
    func newInstallation() {
        #expect(resolve(home: "/Users/tester", present: []) == "/Users/tester/bloom/workspaces.noindex")
    }

    @Test("an installation that already has a root keeps it, whatever its name")
    func existingInstallationKeepsItsRoot() {
        let existing = resolve(home: "/Users/tester", present: ["/Users/tester/bloom/workspaces"])
        #expect(existing == "/Users/tester/bloom/workspaces")
    }

    /// The case that makes the answer stable. Git creates the folder on the way to cutting the
    /// first worktree, so from the second workspace onwards this is what every new installation
    /// looks like, and it has to keep answering the same way.
    @Test("an installation that has cut into the new folder stays in it")
    func newInstallationStaysPut() {
        let root = resolve(home: "/Users/tester", present: ["/Users/tester/bloom/workspaces.noindex"])
        #expect(root == "/Users/tester/bloom/workspaces.noindex")
    }

    /// An empty `~/bloom/workspaces` appearing beside a folder that already holds worktrees must
    /// not move the next one away from them, so the `.noindex` name is looked for first.
    @Test("a legacy folder appearing later does not steal an install already using the new one")
    func bothPresentPrefersTheNewOne() {
        let root = resolve(
            home: "/Users/tester",
            present: ["/Users/tester/bloom/workspaces", "/Users/tester/bloom/workspaces.noindex"]
        )
        #expect(root == "/Users/tester/bloom/workspaces.noindex")
    }

    /// The only supported way to move an existing install onto the new folder, which is why it is
    /// asserted rather than left as a consequence: make the directory, and new worktrees go in it.
    /// Nothing already cut moves, because nothing renames anything.
    @Test("making the folder by hand is how an existing install opts in")
    func optingInByHand() throws {
        let home = TestScratch.unique("home-optin")
        let noindex = (home as NSString).appendingPathComponent("bloom/workspaces.noindex")
        let legacy = (home as NSString).appendingPathComponent("bloom/workspaces")
        for path in [legacy, noindex] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        let root = WorkspacesRoot.resolve(home: URL(fileURLWithPath: home))
        #expect(root.path == noindex)
    }

    @Test("asks a real disk, and reads an existing folder off it")
    func readsARealDisk() throws {
        let home = TestScratch.unique("home-existing")
        let legacy = (home as NSString).appendingPathComponent("bloom/workspaces")
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)

        let root = WorkspacesRoot.resolve(home: URL(fileURLWithPath: home))
        #expect(root.path == legacy)
    }

    @Test("a real disk with nothing on it gets the folder Spotlight skips")
    func readsARealDiskWithNoRoot() throws {
        let home = TestScratch.unique("home-empty")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

        let root = WorkspacesRoot.resolve(home: URL(fileURLWithPath: home))
        let expected = (home as NSString).appendingPathComponent("bloom/workspaces.noindex")
        #expect(root.path == expected)
    }

    /// A plain file of that name is not a root. `fileExists` alone would say yes, and git cannot
    /// create a worktree under it, so the failure would arrive as a git error at create time.
    @Test("a file named workspaces is not a workspaces root")
    func aFileIsNotARoot() throws {
        let home = TestScratch.unique("home-file")
        let bloom = (home as NSString).appendingPathComponent("bloom")
        try FileManager.default.createDirectory(atPath: bloom, withIntermediateDirectories: true)
        let file = (bloom as NSString).appendingPathComponent("workspaces")
        try "not a folder".write(toFile: file, atomically: true, encoding: .utf8)

        let root = WorkspacesRoot.resolve(home: URL(fileURLWithPath: home))
        let expected = (home as NSString).appendingPathComponent("bloom/workspaces.noindex")
        #expect(root.path == expected)
    }

    /// The name is the mechanism, not decoration: a marker file inside the folder was measured not
    /// to work, and only the suffix does.
    @Test("the folder a new installation gets is named for the suffix that does the work")
    func theNameIsTheMechanism() {
        #expect(WorkspacesRoot.preferredName.hasSuffix(".noindex"))
        #expect(!WorkspacesRoot.legacyName.hasSuffix(".noindex"))
    }

    @Test("the settings row says something different to each kind of installation")
    func theNoteExplainsWhichRootThisIs() {
        let new = WorkspacesRoot.note(for: URL(fileURLWithPath: "/Users/tester/bloom/workspaces.noindex"))
        let old = WorkspacesRoot.note(for: URL(fileURLWithPath: "/Users/tester/bloom/workspaces"))
        #expect(new != old)
        #expect(old.contains("keeps the folder it already has"))
        #expect(new.contains(".noindex"))
    }

    /// Read only, and deliberately so: this asserts that the property everything calls is the rule
    /// above and not a second copy of it. It never writes, and on this Mac it answers with the
    /// owner's own root.
    @Test("WorkspaceManager reads the rule rather than repeating it")
    func theManagerUsesTheRule() {
        #expect(WorkspaceManager.workspacesRoot == WorkspacesRoot.resolve())
    }
}
