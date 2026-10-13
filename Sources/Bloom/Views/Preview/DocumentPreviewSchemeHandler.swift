import Foundation
import WebKit
import BloomCore

/// Answers every `bloom-preview://` request a preview makes, and is the only thing in it that
/// reads the disk. See `DocumentPreview` for why a preview has a scheme of its own.
///
/// The document itself is special in two ways. A Markdown file is answered with the page
/// `MarkdownPreviewPage` builds, and a Markdown file linked from it would be too if WebKit ever
/// asked, which it does not, since `DocumentPreviewNavigation` opens that as a file of its own.
/// And unsaved text is answered in place of the bytes on disk, so what the editor holds is what
/// the preview draws.
@MainActor
final class DocumentPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: String
    private let document: String
    /// The editor's unsaved text for the document, or nil when there is none.
    var draft: String?
    /// Tasks WebKit has stopped. Answering one of those raises, so a read that finishes after the
    /// pane moved on is dropped here.
    private var stopped: Set<ObjectIdentifier> = []

    init(root: String, document: String) {
        self.root = root
        self.document = URL(filePath: document).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        stopped.remove(id)
        guard let url = urlSchemeTask.request.url else { return }
        guard let file = DocumentPreview.file(for: url, root: root) else {
            respond(urlSchemeTask, url: url, status: 403, type: "text/plain; charset=utf-8", body: Data("Outside this preview".utf8))
            return
        }
        let draft = file.path == document ? draft : nil
        Task {
            let answer = await Task.detached(priority: .userInitiated) { Self.read(file, draft: draft) }.value
            guard !self.stopped.contains(id) else { return }
            self.respond(urlSchemeTask, url: url, status: answer.status, type: answer.type, body: answer.body)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    private struct Answer: Sendable {
        var status: Int
        var type: String
        var body: Data
    }

    nonisolated private static func read(_ file: URL, draft: String?) -> Answer {
        let type = DocumentPreview.contentType(forFile: file.path)
        do {
            switch DocumentPreview.kind(path: file.path) {
            case .markdown:
                let document = try MarkdownFileDocument.read(path: file.path, draft: draft)
                let page = MarkdownPreviewPage.html(for: document, title: file.lastPathComponent)
                return Answer(status: 200, type: type, body: Data(page.utf8))
            case .html, .svg:
                if let draft {
                    return Answer(status: 200, type: type, body: Data(draft.utf8))
                }
                return Answer(status: 200, type: type, body: try Data(contentsOf: file, options: .mappedIfSafe))
            case nil:
                return Answer(status: 200, type: type, body: try Data(contentsOf: file, options: .mappedIfSafe))
            }
        } catch {
            return Answer(status: 404, type: "text/plain; charset=utf-8", body: Data(error.localizedDescription.utf8))
        }
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        // No caching, so a reload after an agent rewrote the stylesheet beside a report fetches
        // the new one rather than drawing the old.
        let headers = [
            "Content-Type": type,
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
