import AppKit
import Foundation
import Observation
import BloomCore

/// Every site's icon this Mac has seen, by origin, for as long as the app is open and across the
/// next launch.
///
/// **By origin rather than by tab, because a site has one icon.** A reader walking twenty pages of
/// one host asks once, four tabs on the same dev server share the answer, and a tab navigating
/// within its host keeps the icon it has while the next page loads. That last one is not a rule
/// written anywhere: the key does not change, so the lookup does not miss, so nothing flickers.
///
/// **A failure is remembered too.** A page declaring no icon would otherwise be asked again on
/// every navigation for as long as the tab is open. `claim` hands out permission to ask once per
/// origin per launch, and `BrowserSession.reload` gives it back, so pressing reload is how a
/// reader gets a second try at a dev server that has since grown one.
///
/// The cache on disk is `RepoIconImage`'s argument at a longer range: a strip redraws for reasons
/// that have nothing to do with icons, so each is decoded once. It lives in the app's own
/// Application Support directory, which is the dev build's separately from the owner's, and is
/// better lost than migrated.
@MainActor
@Observable
final class BrowserFaviconStore {
    static let shared = BrowserFaviconStore()

    /// What the strip draws. Observed, so an icon landing redraws the tabs and nothing else has to
    /// be told.
    private(set) var icons: [String: NSImage] = [:]

    /// The same icons as bytes, which is what is written back to disk.
    ///
    /// It can hold fewer than `icons` does, deliberately: the file is capped and its oldest
    /// entries fall out, while a site whose tab is on screen keeps its picture for as long as the
    /// app runs. A visible tab must not lose its icon because a hundred and twenty-ninth site was
    /// visited.
    @ObservationIgnored private var entries: [String: Entry] = [:]

    /// Origins already asked about this launch, answered or not. See `claim`.
    @ObservationIgnored private var asked: Set<String> = []

    @ObservationIgnored private var hasWarmed = false

    /// The write in flight, so a run of navigations that each land an icon costs one file write.
    @ObservationIgnored private var writer: Task<Void, Never>?

    private struct Entry: Codable, Sendable {
        var png: Data
        var seen: Date
    }

    private nonisolated static let fileName = "Favicons.plist"

    /// How long a burst of new icons gathers before the file is written.
    private static let writeDelay = Duration.seconds(1)

    private init() {}

    // MARK: - Reading

    /// The icon for whatever page a tab is on, or nil for the globe.
    ///
    /// A dictionary lookup behind one `URL` parse, because it is asked from a tab's body and a
    /// strip redraws on everything: a resize, a hover, a turn arriving three tabs along.
    func icon(for address: String) -> NSImage? {
        guard let origin = BrowserFavicon.origin(of: address) else { return nil }
        return icons[origin]
    }

    // MARK: - Writing

    /// Whether this origin may be asked, and takes the permission if so.
    ///
    /// A page with no icon, a host that will not share one across origins and a server that was
    /// down are all failures that would otherwise repeat on every navigation, at two round trips
    /// into the page each.
    func claim(_ origin: String) -> Bool {
        guard icons[origin] == nil, !asked.contains(origin) else { return false }
        asked.insert(origin)
        return true
    }

    /// Gives an origin its one question back, which is what a reader pressing reload is asking for.
    func forget(_ origin: String) {
        asked.remove(origin)
    }

    /// The bytes of an icon, already through `BrowserFavicon.read`.
    ///
    /// Refused rather than stored if `NSImage` will not have them, or if they draw larger than the
    /// square the page was asked for. Both are impossible from a canvas Bloom sized and both are
    /// checked, because this is the last point before a picture from the network is drawn inside
    /// the app's own chrome.
    func adopt(_ png: Data, for origin: String) {
        guard let image = Self.image(from: png) else { return }
        icons[origin] = image
        entries[origin] = Entry(png: png, seen: Date())
        save()
    }

    /// Reads the cache off disk, once.
    ///
    /// From the strip's own task rather than from launch, because the strip is what needs it: a
    /// workspace reopening on a browser tab should draw its icon on the first frame instead of
    /// asking the page for something this Mac already has. Anything already in hand wins, since an
    /// icon can land while the file is being read.
    func warm() async {
        guard !hasWarmed else { return }
        hasWarmed = true

        let stored = await Task.detached(priority: .utility) { Self.read() }.value
        for (origin, entry) in stored where entries[origin] == nil {
            entries[origin] = entry
            guard icons[origin] == nil, let image = Self.image(from: entry.png) else { continue }
            icons[origin] = image
        }
    }

    // MARK: - The file

    /// Trims the cache to its cap and writes it, after a pause long enough to swallow a burst.
    ///
    /// Oldest by when they were adopted, because there is nothing better to go on: recording a
    /// read would mean writing on every draw.
    private func save() {
        if entries.count > BrowserFavicon.cacheLimit {
            let doomed = entries.sorted { $0.value.seen < $1.value.seen }
                .prefix(entries.count - BrowserFavicon.cacheLimit)
            for (origin, _) in doomed { entries[origin] = nil }
        }

        let snapshot = entries
        writer?.cancel()
        writer = Task {
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { Self.write(snapshot) }.value
        }
    }

    private nonisolated static func read() -> [String: Entry] {
        let url = Store.defaultDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // Our own file in our own container, and still bounded: a decoder handed a file that has
        // been replaced is a decoder that can be made to work for a long time.
        guard data.count <= BrowserFavicon.cacheLimit * (BrowserFavicon.byteLimit + 256) else {
            return [:]
        }
        return (try? PropertyListDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private nonisolated static func write(_ entries: [String: Entry]) {
        let directory = Store.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = PropertyListEncoder()
        // Binary, so the bytes go in as bytes. XML would base64 every icon and make the file a
        // third again as big for nothing.
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// A picture from the network, made into something the strip can draw.
    private static func image(from png: Data) -> NSImage? {
        guard png.count <= BrowserFavicon.byteLimit,
              let image = NSImage(data: png), image.isValid
        else { return nil }

        let ceiling = CGFloat(BrowserFavicon.pixels)
        let size = image.size
        guard size.width > 0, size.height > 0, size.width <= ceiling, size.height <= ceiling else {
            return nil
        }

        // Never a template, and this is the line here with an attacker on the other end of it. A
        // black on transparent icon drawn as one takes the tab's own ink, at which point a page
        // can put something indistinguishable from a control Bloom drew into Bloom's own strip.
        image.isTemplate = false
        return image
    }
}
