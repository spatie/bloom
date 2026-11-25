import Testing
@testable import BloomCore

@Suite("Window title parts")
struct WindowTitlePartsTests {
    @Test("A workspace's title names its project after it")
    func namesTheProject() {
        let parts = WindowTitleParts(name: "oresund-strait", project: "bloom")
        #expect(parts.full == "oresund-strait · bloom")
    }

    @Test("A title with no project is the name alone", arguments: [nil, "", "Bloom"])
    func leavesOutAProjectThatAddsNothing(project: String?) {
        let parts = WindowTitleParts(name: "Bloom", project: project)
        #expect(parts.full == "Bloom")
        #expect(parts.drawn(from: "Bloom") == "Bloom")
    }

    @Test("The title bar draws the name without the project")
    func drawsTheNameAlone() {
        let parts = WindowTitleParts(name: "oresund-strait", project: "bloom")
        #expect(parts.drawn(from: parts.full) == "oresund-strait")
    }

    @Test("A build's prefix on the window's title is still drawn")
    func keepsABuildPrefix() {
        let parts = WindowTitleParts(name: "oresund-strait", project: "bloom")
        #expect(parts.drawn(from: "[DEV] " + parts.full) == "[DEV] oresund-strait")
    }

    @Test("A name that ends like the project keeps its ending")
    func onlyTakesTheProjectOffOnce() {
        let parts = WindowTitleParts(name: "fix · bloom", project: "bloom")
        #expect(parts.drawn(from: parts.full) == "fix · bloom")
    }

    @Test("The worktree goes out as a file URL, spaces escaped")
    func encodesTheFolder() {
        let parts = WindowTitleParts(name: "a", project: "b", folder: "/tmp/my project/a")
        #expect(parts.documentURL == "file:///tmp/my%20project/a/")
    }

    @Test("No folder, no document", arguments: [nil, ""])
    func hasNoDocumentWithoutAFolder(folder: String?) {
        #expect(WindowTitleParts(name: "Bloom", folder: folder).documentURL == nil)
    }
}
