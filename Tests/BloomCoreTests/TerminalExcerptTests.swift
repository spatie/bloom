import Foundation
import Testing
@testable import BloomCore

@Suite("Terminal excerpts")
struct TerminalExcerptTests {
    @Test("An excerpt retains exact selected bytes and provenance after serialisation")
    func snapshot() throws {
        var liveOutput = "before\r\n```\nfailed <test>\n```\n"
        let excerpt = try #require(TerminalExcerpt(
            terminalID: TerminalTabID("shell-1"), workspaceID: WorkspaceID("worktree-1"), label: "Tests",
            firstLine: 14, lastLine: 10, text: liveOutput
        ))
        liveOutput = "terminal cleared"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TerminalExcerpt.self, from: Data(excerpt.attachmentText().utf8))
        #expect(restored.text == "before\r\n```\nfailed <test>\n```\n")
        #expect(restored.terminalID == TerminalTabID("shell-1"))
        #expect(restored.workspaceID == WorkspaceID("worktree-1"))
        #expect(restored.label == "Tests")
        #expect(restored.firstLine == 10)
        #expect(restored.lastLine == 14)
        #expect(restored.text != liveOutput)
    }

    @Test("Blank selection does not create an attachment")
    func empty() {
        let excerpt = TerminalExcerpt(
            terminalID: .new(), workspaceID: .new(), label: "Terminal", firstLine: 1, lastLine: 1, text: " \n"
        )
        #expect(excerpt == nil)
    }
}
