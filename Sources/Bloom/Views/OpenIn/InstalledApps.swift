import SwiftUI
import AppKit
import BloomCore

/// One application that is actually on this Mac: what it is, where it is, and what it looks like.
///
/// The icon is the real one, taken from the bundle, because a row of identical grey glyphs is a
/// list you have to read and a row of app icons is one you recognise.
struct DetectedApp: Identifiable, Hashable {
    var id: String { app.bundleID }
    let app: ExternalApp
    let url: URL
    let icon: NSImage
}

/// Which of the applications Bloom knows about are installed.
///
/// Asked of LaunchServices by bundle id rather than by looking in `/Applications`, so a copy
/// installed by Setapp, by a homebrew cask into `~/Applications`, or kept anywhere else at all is
/// still found. See `EditorCatalog` for why the list is curated rather than taken from the
/// system's own list of handlers.
///
/// Memoised rather than observable. The result is only ever read while a menu is being built, and
/// a menu is built fresh every time it opens, so a plain cache with an age on it picks up an
/// application installed a minute ago without any of the "modifying state during view update"
/// trouble that comes from mutating observable state from inside `body`.
@MainActor
enum InstalledApps {
    /// Long enough that opening a context menu twice in a row costs one scan, short enough that
    /// installing an editor and coming back to Bloom shows it without a relaunch.
    private static let staleAfter: TimeInterval = 60

    private static var cache: [DetectedApp] = []
    private static var scannedAt: Date?
    /// Keyed by file extension. See `systemDefault(forFile:)`.
    private static var systemDefaults: [String: DetectedApp?] = [:]

    static var all: [DetectedApp] {
        if let scannedAt, Date.now.timeIntervalSince(scannedAt) < staleAfter { return cache }
        cache = scan()
        scannedAt = .now
        return cache
    }

    private static func scan() -> [DetectedApp] {
        EditorCatalog.known.compactMap { app in
            guard let url = locate(app) else { return nil }
            return DetectedApp(app: app, url: url, icon: icon(at: url))
        }
    }

    /// Where this application is, if it is here at all.
    ///
    /// LaunchServices first, because it knows about every copy wherever it was installed. The
    /// folder sweep second, because LaunchServices is not always right: see `EditorCatalog`, where
    /// the Xcode this was written against is a working installation it answers `nil` for. The
    /// bundle identifier is checked either way, so a bundle that merely has the right file name is
    /// never mistaken for the application.
    private static func locate(_ app: ExternalApp) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return url
        }
        for folder in folders {
            let url = folder.appendingPathComponent(app.fileName)
            guard Bundle(url: url)?.bundleIdentifier == app.bundleID else { continue }
            return url
        }
        return nil
    }

    /// The folders applications are actually kept in. Setapp included, because it keeps its copies
    /// inside its own folder and a developer using it has no other copy.
    private static let folders: [URL] = [
        "/Applications",
        "/Applications/Utilities",
        "/Applications/Setapp",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// The application the user has themselves set as the default for this kind of file, when it
    /// is not already in the catalogue.
    ///
    /// This is the one place the system gets a say in what the menu contains, and it is a narrow
    /// one on purpose. The full list of registered handlers for a source file is Preview, Safari
    /// and everything that ever claimed a text UTI, which is noise. The single default is the one
    /// entry in that list somebody may have chosen deliberately, so an editor Bloom has never
    /// heard of still turns up in the menu of the person who uses it.
    static func systemDefault(forFile path: String) -> DetectedApp? {
        let key = (path as NSString).pathExtension.lowercased()
        if let cached = systemDefaults[key] { return cached }

        var found: DetectedApp?
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)),
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           !EditorCatalog.knownIDs.contains(bundleID) {
            found = DetectedApp(
                app: ExternalApp(bundleID: bundleID, name: name(of: url), targets: .file),
                url: url,
                icon: icon(at: url)
            )
        }
        systemDefaults[key] = found
        return found
    }

    /// Sized here rather than in the menu, because SwiftUI hands an `NSImage` to AppKit at whatever
    /// size the image says it is, and an application icon says 512 points.
    private static func icon(at url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    /// What Finder calls it, which is the name the user knows and is localised for them.
    private static func name(of url: URL) -> String {
        let display = FileManager.default.displayName(atPath: url.path)
        return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
    }
}
