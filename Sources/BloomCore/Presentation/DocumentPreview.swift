import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A file drawn as the document it describes rather than as its source: Markdown rendered, an
/// HTML report run with its styles and scripts, or an SVG drawn at its native resolution.
///
/// # Why a scheme of its own, and not `file://`
///
/// The browser pane opens a page out of the worktree with `loadFileURL`, and a preview could have
/// done the same for HTML. It does not, for three reasons measured against what agents write.
/// A `file://` page has an opaque origin, so a report that `fetch`es the JSON beside it, or loads
/// its script as a module, fails where it would work from any server. Markdown has no file to
/// load at all, only a string, and a string loaded with a `file://` base gets no read access to
/// the images next to it. And `loadFileURL` grants a whole directory to WebKit, which is then
/// WebKit's to police.
///
/// So every request a preview makes arrives at Bloom as `bloom-preview://worktree/<path>`, and
/// `file(for:root:)` below is the one place that turns an address back into a path. Anything that
/// does not resolve inside the root, symlinks included, is refused there, which is the containment
/// `LocalPage.fileURL` gives the browser, applied per request rather than per directory.
public enum DocumentPreview {
    public enum Kind: Sendable, Equatable {
        case markdown
        case html
        case svg
    }

    public static let scheme = "bloom-preview"
    static let host = "worktree"

    /// Whether a file has a preview at all, asked of its name so nothing is read to find out.
    public static func kind(path: String) -> Kind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": .markdown
        case "html", "htm", "xhtml": .html
        case "svg": .svg
        default: nil
        }
    }

    /// The directory a preview may read from. A workspace file reads its worktree. A file opened
    /// from outside any worktree reads only the folder it sits in, because granting its whole disk
    /// is not what opening one file asked for.
    public static func root(forFile absolutePath: String, worktree: String?) -> String {
        if let worktree, !worktree.isEmpty,
           ContainedPath.resolve(URL(filePath: absolutePath), inside: URL(filePath: worktree, directoryHint: .isDirectory)) != nil {
            return worktree
        }
        return (absolutePath as NSString).deletingLastPathComponent
    }

    /// The address a file is loaded at, or nil for one outside the root.
    public static func address(forFile absolutePath: String, root: String) -> URL? {
        let rootURL = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard let file = ContainedPath.resolve(URL(filePath: absolutePath), inside: rootURL) else { return nil }
        let relative = String(file.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + relative
        return components.url
    }

    /// The file a request names, or nil for anything that is not a preview address inside the root.
    ///
    /// A folder answers with its `index.html`, as a static server would, so a report linking to
    /// `details/` still lands on a page.
    public static func file(for url: URL, root: String) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host, !root.isEmpty else { return nil }
        let rootURL = URL(filePath: root, directoryHint: .isDirectory)
        let relative = url.path(percentEncoded: false)
        guard let resolved = ContainedPath.resolve(rootURL.appending(path: relative), inside: rootURL) else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return ContainedPath.resolve(resolved.appending(path: "index.html"), inside: rootURL)
        }
        return resolved
    }

    /// What a response says it is. Text is declared UTF-8, which is what every file an agent
    /// writes is, because a custom scheme otherwise leaves WebKit to guess Latin-1 for a page with
    /// no `<meta charset>` in it and every accented letter comes out as two.
    public static func contentType(forFile path: String) -> String {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        switch kind(path: path) {
        case .markdown, .html: return "text/html; charset=utf-8"
        case .svg: return "image/svg+xml; charset=utf-8"
        case nil: break
        }
        switch fileExtension {
        case "js", "mjs", "cjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        default: break
        }
        #if canImport(UniformTypeIdentifiers)
        guard let type = UTType(filenameExtension: fileExtension), let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return type.conforms(to: .text) ? "\(mime); charset=utf-8" : mime
        #else
        return "application/octet-stream"
        #endif
    }

    /// What has to differ for a preview to reload: the unsaved text when there is some, otherwise
    /// the file's size and modification date, which is a `stat` rather than a read.
    public static func fingerprint(forFile path: String, draft: String?) -> String {
        if let draft { return "draft:\(draft.hashValue)" }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "disk:\(size):\(modified)"
    }
}

/// What a preview does with a navigation, decided in one place so the rules can be tested.
public enum DocumentPreviewNavigation: Sendable, Equatable {
    /// WebKit goes ahead: a jump to a heading, a reload, a frame inside the page.
    case allow
    /// A click on another file in the worktree, which Bloom opens as a file of its own so the tab
    /// and what it shows cannot come apart.
    case openFile(String)
    /// A click on a web address, which leaves Bloom the way a transcript link does.
    case openExternally(URL)
    case refuse

    /// - Parameters:
    ///   - target: where the navigation is going.
    ///   - document: the file the preview was opened on, as an absolute path.
    ///   - isMainFrame: false for an `iframe` inside the page.
    ///   - isLinkActivated: whether somebody clicked. A script moving the page is not a click, and
    ///     a page that could send Bloom to another file or out to the web on load would be a page
    ///     doing things nobody asked for.
    public static func decide(
        target: URL, document: String, root: String, isMainFrame: Bool, isLinkActivated: Bool
    ) -> Self {
        let scheme = target.scheme?.lowercased() ?? ""
        switch scheme {
        case DocumentPreview.scheme:
            guard let file = DocumentPreview.file(for: target, root: root) else { return .refuse }
            if !isMainFrame { return .allow }
            let current = URL(filePath: document).standardizedFileURL.resolvingSymlinksInPath().path
            if file.path == current { return .allow }
            return isLinkActivated ? .openFile(file.path) : .refuse
        case "about", "data", "blob":
            return isMainFrame ? (target.absoluteString == "about:blank" ? .allow : .refuse) : .allow
        case "http", "https":
            if !isMainFrame { return .allow }
            return isLinkActivated ? .openExternally(target) : .refuse
        case "mailto":
            return isLinkActivated ? .openExternally(target) : .refuse
        default:
            return .refuse
        }
    }
}
