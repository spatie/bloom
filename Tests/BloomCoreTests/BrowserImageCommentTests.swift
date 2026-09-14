import Foundation
import Testing
@testable import BloomCore

@Suite("Browser image comments")
struct BrowserImageCommentTests {
    private let path = ".bloom/attachments/ABC/area.png"

    @Test("The compact chip expands to its comment, URL and screenshot when sent")
    func expandsComment() {
        let note = BrowserImageComment(body: "More space here", address: "http://localhost:3100/settings")
        let chip = AttachmentDraft.token(for: path)
        let sent = BrowserImageComment.expand("Please fix this.\n\(chip)", comments: [path: note])
        #expect(sent == "Please fix this.\nMore space here\nPage: http://localhost:3100/settings\n\(chip)")
        #expect(AttachmentDraft.parse(sent).paths == [path])
    }

    @Test("Removed chips do not send their comments, and ordinary attachments remain unchanged")
    func respectsDraft() {
        let note = BrowserImageComment(body: "Do not send", address: "http://localhost")
        let other = AttachmentDraft.token(for: ".bloom/attachments/DEF/other.png")
        #expect(BrowserImageComment.expand("Only \(other)", comments: [path: note]) == "Only \(other)")
        #expect(BrowserImageComment.expand("", comments: [path: note]).isEmpty)
    }

    @Test("Comment metadata round trips with the attachment")
    func persistsComment() throws {
        let note = BrowserImageComment(body: "First line\nSecond line", address: "https://example.com/?a=b#part")
        let data = try JSONEncoder().encode(note)
        #expect(try JSONDecoder().decode(BrowserImageComment.self, from: data) == note)
    }

    @Test("The comment editor stays inside the pane and avoids the selected area when possible")
    func placesEditor() {
        let bounds = CGRect(x: 0, y: 0, width: 520, height: 600)
        for selection in [CGRect(x: 20, y: 20, width: 100, height: 40), CGRect(x: 40, y: 540, width: 100, height: 40)] {
            let frame = BrowserRegion.commentFrame(near: selection, in: bounds, size: CGSize(width: 380, height: 80))
            #expect(bounds.contains(frame))
            #expect(!frame.intersects(selection))
        }
        let narrow = CGRect(x: 0, y: 0, width: 240, height: 200)
        let frame = BrowserRegion.commentFrame(near: narrow, in: narrow, size: CGSize(width: 380, height: 250))
        #expect(narrow.contains(frame))
        #expect(frame.width == 224 && frame.height == 184)
    }
}
