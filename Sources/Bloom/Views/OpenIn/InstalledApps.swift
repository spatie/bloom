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
    private static var defaultsScannedAt: Date?
    /// The contents of each application folder, held for the length of one `scan` and thrown away
    /// after it. See `listing(of:)`.
    private static var listings: [URL: [String]] = [:]

    static var all: [DetectedApp] {
        if let scannedAt, Date.now.timeIntervalSince(scannedAt) < staleAfter { return cache }
        cache = scan()
        scannedAt = .now
        return cache
    }

    private static func scan() -> [DetectedApp] {
        defer { listings = [:] }
        return EditorCatalog.known.compactMap { app in
            guard let url = locate(app) else { return nil }
            return DetectedApp(app: app, url: url, icon: icon(at: url))
        }
    }

    /// Where this application is, if it is here at all.
    ///
    /// LaunchServices first, because it knows about every copy wherever it was installed, and it
    /// is asked for every identifier the application ships under rather than one: a bundle id
    /// lookup is exact, and `com.jetbrains.PhpStorm` is not what a PhpStorm EAP or Light build
    /// answers to. See `ExternalApp.variantIDs`, which is where the bug that forced this is
    /// written down.
    ///
    /// The folder sweep second, because LaunchServices is not always right: see `EditorCatalog`,
    /// where the Xcode this was written against is a working installation it answers `nil` for.
    /// The bundle identifier is checked either way, through `ExternalApp.matches(bundleID:)`, so
    /// a bundle that merely has the right file name is never mistaken for the application.
    private static func locate(_ app: ExternalApp) -> URL? {
        for bundleID in app.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        for folder in folders {
            let url = folder.appendingPathComponent(app.fileName)
            guard app.matches(bundleID: Bundle(url: url)?.bundleIdentifier) else { continue }
            return url
        }
        return sweep(for: app)
    }

    /// The last resort: a bundle in one of the usual folders that is named after this application
    /// without being named exactly what the catalogue expects.
    ///
    /// `PhpStorm EAP.app` and `PhpStorm 2025.2.app` sit beside `PhpStorm.app` on plenty of Macs,
    /// and a JetBrains Toolbox that has lost its LaunchServices registration leaves one of those
    /// as the only copy there is. `ExternalApp.matchesFileName` narrows a folder to a handful of
    /// bundles worth opening and `matches(bundleID:)` decides, so this can only ever find the
    /// application it was asked for, under a name nobody typed here.
    ///
    /// Reached only for an application neither LaunchServices nor the exact name found, which on
    /// a normal Mac is most of the catalogue and is why the listing of each folder is read once
    /// per scan rather than once per application.
    private static func sweep(for app: ExternalApp) -> URL? {
        for folder in folders {
            for name in listing(of: folder) where app.matchesFileName(name) {
                let url = folder.appendingPathComponent(name)
                guard app.matches(bundleID: Bundle(url: url)?.bundleIdentifier) else { continue }
                return url
            }
        }
        return nil
    }

    /// What is in a folder, read once for the whole of one `scan`.
    private static func listing(of folder: URL) -> [String] {
        if let cached = listings[folder] { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        listings[folder] = names
        return names
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
        // Where JetBrains Toolbox puts an IDE now that it installs into a folder of its own. Its
        // older layout is four levels down under Application Support, keyed by build number, and
        // that one is left to LaunchServices: a sweep that walks it would be reading directories
        // on every scan to find a copy the system already knows about.
        NSHomeDirectory() + "/Applications/JetBrains Toolbox",
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
        // The same age `all` lives under. This half of the cache had none, so choosing a new
        // default app for a file type kept showing the old one in every Open In menu until the
        // app was relaunched.
        if let defaultsScannedAt, Date.now.timeIntervalSince(defaultsScannedAt) >= staleAfter {
            systemDefaults = [:]
        }
        if systemDefaults.isEmpty { defaultsScannedAt = .now }

        let key = (path as NSString).pathExtension.lowercased()
        if let cached = systemDefaults[key] { return cached }

        var found: DetectedApp?
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)),
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           !EditorCatalog.isKnown(bundleID: bundleID) {
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
