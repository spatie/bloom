import Foundation
import Testing
@testable import BloomCore

@Suite("Document preview", .scratchDirectory)
struct DocumentPreviewTests {
    private func worktree() throws -> String {
        let root = TestScratch.path("worktree")
        try FileManager.default.createDirectory(atPath: root + "/docs/assets", withIntermediateDirectories: true)
        for file in ["docs/report.html", "docs/assets/app.css", "docs/plan.md"] {
            try "x".write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        }
        return URL(filePath: root).resolvingSymlinksInPath().path
    }

    @Test("Markdown, HTML and SVG have a preview, other files do not")
    func kinds() {
        #expect(DocumentPreview.kind(path: "README.md") == .markdown)
        #expect(DocumentPreview.kind(path: "docs/Architecture.HTML") == .html)
        #expect(DocumentPreview.kind(path: "index.htm") == .html)
        #expect(DocumentPreview.kind(path: "main.swift") == nil)
        #expect(DocumentPreview.kind(path: "logo.svg") == .svg)
        #expect(DocumentPreview.kind(path: "public/LOGO.SVG") == .svg)
    }

    @Test("a file's address resolves back to the same file, spaces and hashes included")
    func roundTrip() throws {
        let root = try worktree()
        let odd = root + "/docs/draft #2 notes.md"
        try "x".write(toFile: odd, atomically: true, encoding: .utf8)
        let address = try #require(DocumentPreview.address(forFile: odd, root: root))
        #expect(address.scheme == DocumentPreview.scheme)
        #expect(DocumentPreview.file(for: address, root: root)?.path == odd)
    }

    @Test("a relative asset resolves from the document's own folder")
    func relativeAsset() throws {
        let root = try worktree()
        let document = try #require(DocumentPreview.address(forFile: root + "/docs/report.html", root: root))
        let stylesheet = try #require(URL(string: "assets/app.css", relativeTo: document)?.absoluteURL)
        #expect(DocumentPreview.file(for: stylesheet, root: root)?.path == root + "/docs/assets/app.css")
    }

    @Test("an address that climbs out of the worktree is refused")
    func containment() throws {
        let root = try worktree()
        let outside = try #require(URL(string: "bloom-preview://worktree/../outside.txt"))
        #expect(DocumentPreview.file(for: outside, root: root) == nil)
        let encoded = try #require(URL(string: "bloom-preview://worktree/docs/%2E%2E/%2E%2E/%2E%2E/etc/passwd"))
        #expect(DocumentPreview.file(for: encoded, root: root) == nil)
        #expect(DocumentPreview.file(for: URL(filePath: root + "/docs/plan.md"), root: root) == nil)
    }

    @Test("a symlink out of the worktree is refused")
    func symlink() throws {
        let root = try worktree()
        let secret = TestScratch.path("secret.txt")
        try "secret".write(toFile: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/docs/link.txt", withDestinationPath: secret)
        let address = try #require(URL(string: "bloom-preview://worktree/docs/link.txt"))
        #expect(DocumentPreview.file(for: address, root: root) == nil)
    }

    @Test("a folder answers with its index page")
    func folderIndex() throws {
        let root = try worktree()
        try "x".write(toFile: root + "/docs/index.html", atomically: true, encoding: .utf8)
        let address = try #require(URL(string: "bloom-preview://worktree/docs/"))
        #expect(DocumentPreview.file(for: address, root: root)?.path == root + "/docs/index.html")
    }

    @Test("a file outside any worktree reads only its own folder")
    func rootOutsideWorktree() throws {
        let root = try worktree()
        #expect(DocumentPreview.root(forFile: root + "/docs/plan.md", worktree: root) == root)
        #expect(DocumentPreview.root(forFile: "/tmp/elsewhere/plan.md", worktree: root) == "/tmp/elsewhere")
        #expect(DocumentPreview.root(forFile: "/tmp/elsewhere/plan.md", worktree: nil) == "/tmp/elsewhere")
    }

    @Test("text is declared UTF-8 and a document is served as HTML")
    func contentTypes() {
        #expect(DocumentPreview.contentType(forFile: "plan.md") == "text/html; charset=utf-8")
        #expect(DocumentPreview.contentType(forFile: "app.css") == "text/css; charset=utf-8")
        #expect(DocumentPreview.contentType(forFile: "app.mjs") == "text/javascript; charset=utf-8")
        #expect(DocumentPreview.contentType(forFile: "logo.svg") == "image/svg+xml; charset=utf-8")
        #expect(DocumentPreview.contentType(forFile: "flow.png") == "image/png")
        #expect(DocumentPreview.contentType(forFile: "blob.unknownextension") == "application/octet-stream")
    }

    @Test("the fingerprint moves when the file or its unsaved text does")
    func fingerprint() throws {
        let root = try worktree()
        let path = root + "/docs/plan.md"
        let before = DocumentPreview.fingerprint(forFile: path, draft: nil)
        try "longer contents".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(DocumentPreview.fingerprint(forFile: path, draft: nil) != before)
        #expect(DocumentPreview.fingerprint(forFile: path, draft: "a") != DocumentPreview.fingerprint(forFile: path, draft: "b"))
        #expect(DocumentPreview.fingerprint(forFile: root + "/missing.md", draft: nil) == "missing")
    }

    // MARK: - Navigation

    private func decide(_ target: String, root: String, mainFrame: Bool = true, clicked: Bool = true) throws -> DocumentPreviewNavigation {
        DocumentPreviewNavigation.decide(
            target: try #require(URL(string: target)), document: root + "/docs/report.html", root: root,
            isMainFrame: mainFrame, isLinkActivated: clicked
        )
    }

    @Test("the document itself loads, fragment and all")
    func sameDocument() throws {
        let root = try worktree()
        #expect(try decide("bloom-preview://worktree/docs/report.html", root: root, clicked: false) == .allow)
        #expect(try decide("bloom-preview://worktree/docs/report.html#costs", root: root) == .allow)
    }

    @Test("a click on another worktree file opens it in Bloom, a script moving the page does not")
    func otherFile() throws {
        let root = try worktree()
        #expect(try decide("bloom-preview://worktree/docs/plan.md", root: root) == .openFile(root + "/docs/plan.md"))
        #expect(try decide("bloom-preview://worktree/docs/plan.md", root: root, clicked: false) == .refuse)
        #expect(try decide("bloom-preview://worktree/docs/plan.md", root: root, mainFrame: false, clicked: false) == .allow)
    }

    @Test("a web link opens outside Bloom only when clicked, and a frame may embed the web")
    func webLinks() throws {
        let root = try worktree()
        let url = try #require(URL(string: "https://spatie.be"))
        #expect(try decide("https://spatie.be", root: root) == .openExternally(url))
        #expect(try decide("https://spatie.be", root: root, clicked: false) == .refuse)
        #expect(try decide("https://spatie.be", root: root, mainFrame: false, clicked: false) == .allow)
    }

    @Test("other schemes are refused")
    func otherSchemes() throws {
        let root = try worktree()
        #expect(try decide("file:///etc/passwd", root: root) == .refuse)
        #expect(try decide("javascript:alert(1)", root: root) == .refuse)
        #expect(try decide("x-apple-something://open", root: root) == .refuse)
        #expect(try decide("data:text/html,hi", root: root) == .refuse)
        #expect(try decide("about:srcdoc", root: root, mainFrame: false, clicked: false) == .allow)
    }
}
