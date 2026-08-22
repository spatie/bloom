import AppKit
import Foundation
import BloomCore

/// Preserves Conductor deep links so existing scripts can hand work to Bloom unchanged.
@MainActor
enum BloomDeepLink {
    /// The schemes this copy actually answers to, read off its own bundle rather than written out.
    ///
    /// It was the literal `"bloom"`, and `Tools/dev-build.sh` rebrands the registered scheme to
    /// `bloomdev` so the dev copy cannot swallow a link meant for the real one. The result was a
    /// dev build that registered `bloomdev://`, received them, and then refused every one with
    /// "The link must include a prompt and project path", which is not what was wrong with it.
    /// Reading `CFBundleURLTypes` means the check can only ever disagree with LaunchServices if
    /// the plist does.
    static let schemes: Set<String> = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let registered = (types ?? [])
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { $0.lowercased() }

        // A bundle with no URL types is `swift run` or a test host. Falling back to the shipped
        // scheme keeps those working rather than making every link fail in a way that reads as a
        // malformed link.
        return registered.isEmpty ? ["bloom"] : Set(registered)
    }()

    /// The Apple Event handler and SwiftUI's onOpenURL can both see the same link, and creating
    /// the same workspace twice is a lot more annoying than dropping a genuine duplicate that
    /// arrived within a second of the first.
    private static var lastHandled: (url: URL, at: Date)?

    static func open(_ url: URL, in app: AppModel) {
        if let last = lastHandled, last.url == url, Date.now.timeIntervalSince(last.at) < 2 {
            return
        }
        lastHandled = (url, .now)

        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
              let values = values(from: url),
              let prompt = values["prompt"]?.removingPercentEncoding,
              let path = values["path"]?.removingPercentEncoding,
              !prompt.isEmpty,
              !path.isEmpty else {
            app.alert = BloomAlert(
                title: "Could not open the Bloom link",
                message: "The link must include a prompt and project path."
            )
            return
        }

        let requestedPath = canonicalPath(path)
        guard let repo = app.repos.first(where: { canonicalPath($0.path) == requestedPath }) else {
            app.alert = BloomAlert(
                title: "Project not found",
                message: "The path in this link is not one of Bloom's projects: \(path)"
            )
            return
        }

        Task { await app.createWorkspace(in: repo, prompt: prompt) }
    }

    private static func values(from url: URL) -> [String: String]? {
        let absolute = url.absoluteString
        guard let separator = absolute.range(of: "://") else { return nil }
        var payload = String(absolute[separator.upperBound...])
        if payload.hasPrefix("?") { payload.removeFirst() }

        var values: [String: String] = [:]
        for pair in payload.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            values[String(pieces[0])] = String(pieces[1]).replacing("+", with: " ")
        }
        return values
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
