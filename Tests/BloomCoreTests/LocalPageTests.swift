import Foundation
import Testing
@testable import BloomCore

@Suite("Local page")
struct LocalPageTests {
    /// A worktree of sorts: a real directory, removed when the test that made it is over.
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("<html></html>".utf8).write(to: file)
        return file
    }

    // MARK: - Which files are pages

    @Test("HTML is a page, in either spelling and in either case")
    func acceptsHTML() {
        #expect(LocalPage.isPage(path: "index.html"))
        #expect(LocalPage.isPage(path: "docs/report.htm"))
        #expect(LocalPage.isPage(path: "INDEX.HTML"))
    }

    /// The review pane draws an SVG's XML, because `FileMediaView.isMedia` refuses one: it
    /// conforms to `.sourceCode` as well as to `.image`. A browser is the only place in the window
    /// that draws the picture, which is the whole reason it is on the list.
    @Test("An SVG is a page, because nothing else in the window draws it")
    func acceptsSVG() {
        #expect(LocalPage.isPage(path: "public/logo.svg"))
    }

    /// Markdown has a viewer of its own here and a PDF and a screenshot have `FileMediaView`. An
    /// item offering a second and worse viewer for the file somebody is looking at is the reason
    /// these are out.
    @Test("What another pane already draws is not offered")
    func refusesWhatIsDrawnElsewhere() {
        #expect(!LocalPage.isPage(path: "README.md"))
        #expect(!LocalPage.isPage(path: "docs/spec.pdf"))
        #expect(!LocalPage.isPage(path: "shot.png"))
        #expect(!LocalPage.isPage(path: "Sources/App.swift"))
        #expect(!LocalPage.isPage(path: "Makefile"))
        #expect(!LocalPage.isPage(path: ""))
    }

    // MARK: - Which rows the item appears on

    @Test("A page on disk is offered")
    func offersAPageOnDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("index.html", in: root)

        #expect(LocalPage.canOpen(file: file.path))
        let address = try #require(LocalPage.address(forFile: file.path))
        #expect(URL(string: address)?.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    /// The changed file list is drawn from a diff, so it keeps a row for a file the agent deleted.
    /// That row is a name with nothing behind it, and a browser opened on one is a tab saying the
    /// file could not be found.
    @Test("A deleted file is not offered")
    func refusesAFileThatIsGone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("removed.html").path

        #expect(!LocalPage.canOpen(file: gone))
        #expect(LocalPage.address(forFile: gone) == nil)
    }

    @Test("A directory called index.html is not a page")
    func refusesADirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("index.html", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(!LocalPage.canOpen(file: directory.path))
    }

    /// A worktree holds folders with spaces in them, and `#` and `?` besides. Written out by hand
    /// the first of those ends the address and the others start a fragment or a query.
    @Test("The address is built rather than spelled out")
    func encodesTheAwkwardCharacters() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("draft #2/index.html", in: root)

        let address = try #require(LocalPage.address(forFile: file.path))
        #expect(address.hasPrefix("file://"))
        #expect(!address.contains(" "))
        #expect(!address.contains("#"))
        #expect(URL(string: address)?.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    // MARK: - What a pane may load

    @Test("A page inside the worktree loads")
    func loadsInsideTheRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("docs/report.html", in: root)

        let resolved = LocalPage.fileURL(from: file.absoluteString, root: root.path)
        #expect(resolved?.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    /// The read access `loadFileURL` takes is the whole worktree, so handing it over is only
    /// defensible while the page came out of that worktree. This is the address field's gate as
    /// much as the menu's.
    @Test("A file outside the worktree is refused")
    func refusesOutsideTheRoot() throws {
        let root = try makeRoot()
        let neighbour = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: neighbour)
        }
        let outside = try write("index.html", in: neighbour)

        #expect(LocalPage.fileURL(from: outside.absoluteString, root: root.path) == nil)
    }

    /// `/w/bloom` must not claim `/w/bloom-old/index.html`, which is what comparing the two
    /// strings without a separator between them would do.
    @Test("A worktree does not claim its neighbour by name")
    func refusesASiblingWithTheSamePrefix() throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("bloom", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sibling = try write("bloom-old/index.html", in: parent)

        #expect(LocalPage.fileURL(from: sibling.absoluteString, root: root.path) == nil)
    }

    @Test("A path that climbs out of the worktree is refused")
    func refusesAClimbingPath() throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try write("secret.html", in: parent)

        let climbing = "file://" + root.path + "/../secret.html"
        #expect(LocalPage.fileURL(from: climbing, root: root.path) == nil)
    }

    /// Everything that is not a local page goes on down `BrowserSession.load` to the parser that
    /// has always handled it, so this has to answer nothing for an ordinary address.
    @Test("An http address is not this function's business")
    func ignoresAServerAddress() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LocalPage.fileURL(from: "http://localhost:3000/", root: root.path) == nil)
        #expect(LocalPage.fileURL(from: "https://spatie.be", root: root.path) == nil)
        #expect(LocalPage.fileURL(from: "", root: root.path) == nil)
    }

    /// A session belonging to no workspace, which is the design gallery's, has no worktree to
    /// grant. It loads no local page at all rather than granting something it guessed at.
    @Test("No worktree means no local page")
    func refusesWithoutARoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("index.html", in: root)

        #expect(LocalPage.fileURL(from: file.absoluteString, root: "") == nil)
    }

    /// `BrowserAddress.shows` is what `BrowserTab.openWindow` asks before a page's own
    /// `window.open` is honoured. It refuses every `file://` there is, and this feature must not
    /// have widened it.
    @Test("The address rule still refuses a file URL")
    func leavesTheAddressRuleAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("index.html", in: root)

        #expect(!BrowserAddress.shows(file))
        #expect(BrowserAddress.external(from: file.absoluteString) == nil)
    }
}
