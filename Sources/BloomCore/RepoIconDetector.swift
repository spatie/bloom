import Foundation

/// The artwork a project already has on disk, found once when the project is added.
///
/// A monogram identifies a project by its name, which is always available and never wrong. It is
/// not, however, the mark the project already has: a site has a favicon, a Mac app has an `.icns`,
/// and a folder that carries either of those is a folder whose owner has already decided what it
/// looks like. This looks for that decision in the places the conventions put it, ranks what it
/// finds, and answers with one file or with nothing.
///
/// Everything here is local and synchronous. No network, no GitHub, no credential, nothing that
/// can hang. The whole point is that the answer is on disk already: it is free, it is offline, and
/// for a repository that has an icon it is more accurate than anything a remote guess could
/// produce. See the note on `candidates(in:)` for why the search is a fixed list of places rather
/// than a walk of the whole tree.
///
/// Pure and in the core so the ranking is pinned by tests rather than judged from a screenshot.
/// Nothing here decodes an image or knows what a colour is: it reads the few header bytes that
/// state a file's real format and dimensions, which is also what makes a file that is named
/// `favicon.png` and is not a PNG fall out of the ranking rather than into the sidebar.
///
/// ## Why there is no remote half
///
/// Fetching the favicon of a domain the repository names (`homepage` in `package.json` or in
/// `composer.json`, the homepage on the GitHub remote) was considered and deliberately left out.
///
/// It would buy almost nothing. A site that states a homepage is a site with a favicon, and a
/// site's favicon is committed to the site's own repository: every case the network could answer
/// is a case the paths above already answer, from disk, instantly. The exceptions are repositories
/// that publish from somewhere else entirely, which are rare, and for which the monogram is not a
/// bad answer.
///
/// It would cost a great deal. An HTTP client with a timeout, a redirect policy, a cache with an
/// expiry, HTML parsing to find `<link rel="icon">`, and content sniffing of bytes fetched from
/// somewhere nobody vouched for. And it would change what adding a project means: today it reads a
/// folder, and it would start making a request to a third party, from the user's address, because
/// of a string in a file in a repository they happened to open. That is not a trade this feature
/// is worth, so adding a project stays a local operation and always finishes offline.
public enum RepoIconDetector {
    /// Below this, a raster loses to the monogram.
    ///
    /// The badge is `Metrics.repoIcon`, 16 points, which is 32 pixels on every Mac display made
    /// this decade. A 32 pixel source is therefore exactly one pixel per pixel, and the classic
    /// 16 pixel `favicon.ico` is a two times upscale: soft, muddy, and worse than the clean pair
    /// of letters it would be replacing. A blurry icon is not an improvement over a monogram, so
    /// anything under this is not offered at all.
    public static let smallestUsefulPixels = 32

    /// How far from square a candidate may be.
    ///
    /// The badge is a square tile, so a picture wider than this is drawn as a band across the
    /// middle of it with empty space above and below, which reads as a broken icon rather than as
    /// a mark. It is also the shape of the thing most often committed as `logo.svg`: a wordmark,
    /// which is the project's name written out, and the project's name is already on the row.
    public static let widestUsefulAspect = 2.0

    /// The best candidate, or nil when the repository has nothing worth drawing.
    public static func detect(in repo: String) -> RepoIconCandidate? {
        candidates(in: repo).first
    }

    /// The layers of a macOS 26 Icon Composer document, bottom first, as absolute paths.
    ///
    /// Public because a `.layered` candidate is a directory rather than a picture, so whatever
    /// draws it has to be told what is inside. Everything about reading the document itself, and
    /// about what Bloom can and cannot reproduce of it, is on `RepoIconFile.layers(ofIconBundle:)`.
    public static func layers(ofIconBundle path: String) -> [String] {
        RepoIconFile.layers(ofIconBundle: path)
    }

    /// Every candidate, best first.
    ///
    /// Two searches, because the two kinds of icon are kept in two kinds of place. Web artwork
    /// lives at a handful of conventional paths (`public/favicon.svg` and its neighbours), so it
    /// is looked for by name in a fixed list of directories: a full walk would be slower and would
    /// also happily pick up a logo from a test fixture or a vendored dependency. Application
    /// artwork is the opposite: an `.icns` or an `AppIcon.appiconset` sits wherever the project's
    /// own layout put it, so that half is a bounded walk which skips the directories that make a
    /// checkout large.
    public static func candidates(in repo: String) -> [RepoIconCandidate] {
        let root = (repo as NSString).expandingTildeInPath
        var found = webCandidates(in: root) + manifestCandidates(in: root) + appCandidates(in: root)

        // A file can be reached by more than one of the rules above: `public` is both a web root
        // and, for a project laid out differently, a brand folder. The best reading of a path is
        // the one that wins, and the rest are dropped so a list of candidates is a list of files.
        found.sort { $0.isBetter(than: $1) }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Web artwork

    /// The directories a site's artwork is kept in, relative to the repository root.
    ///
    /// The empty string is the root itself. Each of these is also looked in one level deeper
    /// through `iconFolders`, which is what finds `public/brand/favicon-32.png` without walking
    /// anything. Not recursive beyond that: two levels covers every layout these conventions
    /// actually appear in, and a deeper search starts finding other people's icons.
    static let webRoots = ["", "public", "static", "www", "assets", "resources", "web", "site", "docs"]

    /// The folder inside a web root that artwork tends to be filed under.
    static let iconFolders = ["", "brand", "icons", "icon", "img", "images", "favicon", "favicons"]

    private static func webCandidates(in root: String) -> [RepoIconCandidate] {
        var candidates: [RepoIconCandidate] = []
        for directory in searchDirectories(in: root) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                guard let origin = origin(ofFileNamed: name) else { continue }
                let path = (directory as NSString).appendingPathComponent(name)
                if let candidate = candidate(at: path, origin: origin) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    /// Every directory the name rules are applied in, deduplicated and in a stable order.
    static func searchDirectories(in root: String) -> [String] {
        var directories: [String] = []
        var seen = Set<String>()
        for web in webRoots {
            for folder in iconFolders {
                let relative = [web, folder].filter { !$0.isEmpty }
                guard let path = resolve(relative, under: root), seen.insert(path).inserted else { continue }
                directories.append(path)
            }
        }
        return directories
    }

    /// The real path of a directory named here in lower case.
    ///
    /// The names above are written the way a web project writes them, and a Swift package writes
    /// the same folder `Resources`. On the case insensitive volume a Mac formats by default both
    /// spellings open the same directory, so joining the strings blind produces two paths to one
    /// file, which is one candidate arriving twice under two names. Resolving each component
    /// against what is actually on disk gives the file one path, and does so without assuming
    /// which kind of volume the repository is on.
    private static func resolve(_ components: [String], under root: String) -> String? {
        var path = root
        for component in components {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            guard let match = entries.first(where: { $0 == component })
                ?? entries.sorted().first(where: { $0.lowercased() == component })
            else { return nil }
            path = (path as NSString).appendingPathComponent(match)
        }
        return isDirectory(path) ? path : nil
    }

    /// What a file name says the file is for, or nil when it says nothing.
    ///
    /// Names only. Whether the bytes back the name up is `RepoIconFile`'s question, and it is
    /// asked afterwards precisely so that a `logo.svg` full of HTML is refused.
    static func origin(ofFileNamed name: String) -> RepoIconOrigin? {
        let lower = name.lowercased()
        guard RepoIconFormat.fileFormats
            .flatMap(\.fileExtensions)
            .contains(where: { lower.hasSuffix(".\($0)") })
        else { return nil }
        return origin(ofStem: (lower as NSString).deletingPathExtension)
    }

    /// The same question asked of a name that has already had its extension taken off, which is
    /// how `decoration(ofFileNamed:)` asks it of the shorter names inside a longer one.
    static func origin(ofStem stem: String) -> RepoIconOrigin? {
        if stem == "favicon" || stem.hasPrefix("favicon-") || stem.hasPrefix("favicon_")
            || stem.hasPrefix("apple-touch-icon") {
            return .favicon
        }

        // `mark` and `logomark` are the square marks; `wordmark` deliberately is not one, and a
        // banner or an Open Graph card is a picture of the project rather than a mark for it.
        // `avatar` is here because a personal site's identity is a face rather than a glyph: on
        // `freek.dev` the only artwork that is the site is `images/avatar-boxed.jpg`.
        //
        // Each of these counts on its own and as the start of a longer name, so `avatar-boxed`,
        // `logo-dark` and `mark_512` are all found. Which of the longer names is the one to draw
        // is the ranking's problem rather than this one's: see `decoration(ofFileNamed:)` and
        // `RepoIconCandidate.shape`. Deliberately still absent are `wordmark`, `banner`, `hero`,
        // `cover`, `og-image` and `screenshot`, every one of which is a picture of the project
        // rather than a mark for it, and none of which get better by being cropped to a 16 point
        // square.
        let brandStems = ["icon", "logo", "mark", "logomark", "appicon", "app-icon", "brand", "avatar"]
        for brand in brandStems
        where stem == brand || stem.hasPrefix("\(brand)-") || stem.hasPrefix("\(brand)_") {
            return .brand
        }
        return nil
    }

    // MARK: - How dressed up a name is

    /// How many words have been added to the plainest name this file could have had.
    ///
    /// The rule the ranking needs is "prefer the least decorated name", and this is the number it
    /// compares. `favicon.svg` is nothing added, so zero. `favicon-unread-1.svg` is the same
    /// artwork with an unread count drawn on it, so one. `logo-dark.svg` is one. A file that got
    /// two words is two. Nothing here knows what `unread` or `dark` or `hover` mean, and that is
    /// the entire point: a list of words to demote would have to be added to for ever, and the
    /// next project will use a word nobody has thought of.
    ///
    /// Two things are not decoration.
    ///
    /// A **size** is not: `favicon-96x96.png`, `icon-512.png` and `Icon-60@2x.png` are the same
    /// artwork drawn bigger or smaller, which is what the pixel comparison further down the
    /// ranking is for. Recognised by shape rather than by a list: a segment of digits, `x` and
    /// `@` with at least one digit in it is a measurement. The cost is that a `logo-2.svg` that
    /// really is a second, different logo reads as a size, which is a fair price for never having
    /// to guess at a word.
    ///
    /// The **name of the role itself** is not, however many words it is spelled with.
    /// `apple-touch-icon.png` is three words and none of them are added: it is what that file is
    /// called. That falls out for free rather than needing a list of its own, because a word only
    /// counts once the name without it is still a name `origin(ofStem:)` recognises, and
    /// `apple-touch` is not.
    ///
    /// Zero for a name that is not one of these conventions at all, such as a manifest's
    /// `web-app-manifest-512x512.png` or an application's `MyApp.icns`. There is no plainer name
    /// for those to be measured against, so there is nothing to say, and saying nothing leaves
    /// them ranked exactly as they were.
    static func decoration(ofFileNamed name: String) -> Int {
        let stem = ((name as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
        guard origin(ofStem: stem) != nil else { return 0 }

        var segments = stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        var added = 0
        while segments.count > 1 {
            let last = segments.removeLast()
            // The shorter name has to still be a name. When it is not, the word just removed was
            // part of what the file is called rather than something added to it.
            guard origin(ofStem: segments.joined(separator: "-")) != nil else { break }
            if !isMeasurement(last) { added += 1 }
        }
        return added
    }

    /// Whether a segment of a name states a size rather than adding a word to it.
    private static func isMeasurement(_ segment: String) -> Bool {
        guard segment.contains(where: \.isNumber) else { return false }
        return segment.allSatisfy { $0.isNumber || $0 == "x" || $0 == "@" }
    }

    // MARK: - Web manifests

    /// The icons a web manifest declares, resolved against the manifest's own directory.
    ///
    /// Worth reading rather than guessing at, because a manifest states which file the site itself
    /// considers its icon, and it is the one place a project can say so out loud. It is also the
    /// one file here whose name is ambiguous: `manifest.json` is equally the name of a Vite build
    /// manifest, a browser extension manifest and half a dozen other things, so a file only counts
    /// when it really is an object with an `icons` array of objects with a `src`.
    private static func manifestCandidates(in root: String) -> [RepoIconCandidate] {
        var candidates: [RepoIconCandidate] = []
        for directory in searchDirectories(in: root) {
            for name in ["site.webmanifest", "manifest.webmanifest", "manifest.json"] {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let data = boundedContents(ofFile: path, limit: 256 * 1024),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let icons = object["icons"] as? [[String: Any]]
                else { continue }

                for icon in icons {
                    guard let source = icon["src"] as? String, !source.isEmpty else { continue }
                    // A manifest states a URL path, which is rooted at the site's document root
                    // rather than at the file. `/brand/icon-512.png` beside the manifest means the
                    // file in this directory's tree, not one at the top of the checkout.
                    let relative = source.hasPrefix("/") ? String(source.dropFirst()) : source
                    guard !relative.isEmpty, !relative.contains("://") else { continue }
                    let resolved = (directory as NSString).appendingPathComponent(relative)
                    if let candidate = candidate(at: resolved, origin: .manifest) {
                        candidates.append(candidate)
                    }
                }
            }
        }
        return candidates
    }

    // MARK: - Application artwork

    /// Directories a walk does not go into.
    ///
    /// Every one of these is either not the project's own code or is large enough to make the walk
    /// noticeable, and several are both. `.app` is in here because a built copy of the application
    /// contains the very icon being looked for, and finding it inside `.build` would mean the
    /// answer changed depending on whether the project had been compiled.
    static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "vendor", "Pods", "Carthage", "build", ".build",
        "DerivedData", "dist", "out", "target", ".venv", "venv", "__pycache__", ".next", ".nuxt",
        ".cache", "coverage", "tmp", "bower_components", ".gradle", ".idea", ".swiftpm",
    ]

    /// How far down the walk goes. Deep enough for `MyApp/Assets.xcassets/AppIcon.appiconset` and
    /// for a package that keeps its resources a folder further in, shallow enough to stay quick.
    static let maximumDepth = 5

    /// A ceiling on how much of a checkout is looked at, so a repository with an enormous tree
    /// that the skip list happens not to cover cannot turn adding a project into a pause.
    static let maximumEntries = 20_000

    private static func appCandidates(in root: String) -> [RepoIconCandidate] {
        var candidates: [RepoIconCandidate] = []
        var visited = 0
        var queue: [(path: String, depth: Int)] = [(root, 0)]

        while !queue.isEmpty, visited < maximumEntries {
            let (directory, depth) = queue.removeFirst()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
            for name in names {
                visited += 1
                if visited >= maximumEntries { break }
                let path = (directory as NSString).appendingPathComponent(name)

                if name.hasSuffix(".icns") {
                    if let candidate = candidate(at: path, origin: .appIcon) { candidates.append(candidate) }
                    continue
                }
                guard isDirectory(path) else { continue }

                if name.hasSuffix(".appiconset") {
                    if let candidate = largestImage(inAppIconSet: path) { candidates.append(candidate) }
                    continue
                }
                if name.hasSuffix(".icon") {
                    if let candidate = candidate(at: path, origin: .appIcon) { candidates.append(candidate) }
                    continue
                }
                guard depth + 1 <= maximumDepth,
                      !skippedDirectories.contains(name),
                      !name.hasPrefix("."),
                      !name.hasSuffix(".app")
                else { continue }
                queue.append((path, depth + 1))
            }
        }
        return candidates
    }

    /// The biggest PNG in an asset catalogue's app icon set.
    ///
    /// The files are read rather than `Contents.json`, because the sizes stated there are point
    /// sizes with a scale beside them and the file is what actually has to be drawn. An icon set
    /// whose PNGs are all missing, which is what a catalogue looks like after a bad merge, has no
    /// candidate rather than a broken one.
    private static func largestImage(inAppIconSet path: String) -> RepoIconCandidate? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
        return names
            .compactMap { candidate(at: (path as NSString).appendingPathComponent($0), origin: .appIcon) }
            .min { $0.isBetter(than: $1) }
    }

    // MARK: - Measuring

    /// One file weighed up, or nil when it is too small, unreadable, or not the thing it is named.
    static func candidate(at path: String, origin: RepoIconOrigin) -> RepoIconCandidate? {
        guard let measurement = RepoIconFile.measure(path) else { return nil }
        if measurement.format.isRaster, measurement.pixels < smallestUsefulPixels { return nil }
        if let aspect = measurement.aspect, aspect > widestUsefulAspect { return nil }
        return RepoIconCandidate(
            path: path,
            format: measurement.format,
            origin: origin,
            pixels: measurement.pixels,
            aspect: measurement.aspect,
            decoration: decoration(ofFileNamed: path)
        )
    }

    /// Whether one of these names is the same kind of artwork wearing a plainer name.
    ///
    /// The question a stored answer asks of the folder it came out of: is the file Bloom picked
    /// the dressed up one, with the plain one sitting beside it all along. Names only, so it costs
    /// one listing of one directory and reads no file at all. See `RepoIconRefresh`, which is the
    /// only caller and where the reason for asking is written down.
    ///
    /// Deliberately narrow. The same extension and the same origin, so this answers "the ranking
    /// would demote this now" rather than "the folder has something else in it". A plainer sibling
    /// in a better format would be a candidate that beat this one on format when it was picked,
    /// which means it was not there at the time, and artwork appearing in a folder is not a reason
    /// to change a mark under somebody.
    static func hasPlainerName(than name: String, among names: [String]) -> Bool {
        let name = (name as NSString).lastPathComponent
        guard let kind = origin(ofFileNamed: name) else { return false }
        let added = decoration(ofFileNamed: name)
        guard added > 0 else { return false }
        let fileExtension = (name as NSString).pathExtension.lowercased()

        return names.contains { other in
            other.lowercased() != name.lowercased()
                && (other as NSString).pathExtension.lowercased() == fileExtension
                && origin(ofFileNamed: other) == kind
                && decoration(ofFileNamed: other) < added
        }
    }

    // MARK: - Files

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Reads a file only if it is small enough to be the thing it claims to be. A manifest is a
    /// few hundred bytes; anything that is megabytes is something else wearing the name.
    static func boundedContents(ofFile path: String, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= limit
        else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}

// MARK: - Candidate

/// Where a candidate was found. Higher is more likely to be what the project means by itself.
///
/// An application's own icon outranks a favicon because a project that ships an `.icns` IS that
/// application, where a favicon can equally belong to a documentation site that happens to live in
/// the same checkout. A favicon outranks a manifest entry only to keep the answer stable when both
/// name the same artwork at different sizes, and both outrank a loose `logo.png`, which is as
/// often a wordmark or a README banner as it is a mark.
public enum RepoIconOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case brand
    case manifest
    case favicon
    case appIcon

    var rank: Int {
        switch self {
        case .brand: 1
        case .manifest: 2
        case .favicon: 3
        case .appIcon: 4
        }
    }
}

/// The file formats worth drawing a project by.
///
/// Deliberately short. A GIF is an animation and a TIFF is a scan, and neither is anybody's mark.
/// `layered` is a macOS 26 Icon Composer document, which is a directory rather than a file.
///
/// JPEG was left out at first, on the grounds that a `logo.jpg` is a picture of a logo on a white
/// rectangle and that a white rectangle is what a 16 point tile would show. That is true of a
/// logo and false of a face: a personal site's mark is a photograph, it is the only artwork such
/// a site has, and refusing the format meant answering `freek.dev` with initials while a 934
/// pixel square portrait of its author sat in `public/images`. So it is in, at the bottom of the
/// order, and the reasoning that kept it out is now carried by the rules that were always doing
/// the real work: a picture more than twice as wide as it is tall is refused outright, and among
/// what survives the squarer artwork wins.
public enum RepoIconFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case svg
    case icns
    case layered
    case png
    case ico
    case jpeg

    /// The formats that are a single file found by extension. `layered` is a bundle and is found
    /// by the walk instead.
    static var fileFormats: [RepoIconFormat] { [.svg, .png, .ico, .icns, .jpeg] }

    /// What the format is written as, including the second spelling where it has one.
    var fileExtensions: [String] {
        switch self {
        case .svg: ["svg"]
        case .icns: ["icns"]
        case .layered: ["icon"]
        case .png: ["png"]
        case .ico: ["ico"]
        case .jpeg: ["jpg", "jpeg"]
        }
    }

    /// Whether the format has a fixed number of pixels in it, and therefore a floor to clear.
    public var isRaster: Bool {
        switch self {
        case .svg, .layered: false
        case .icns, .png, .ico, .jpeg: true
        }
    }

    /// How well the format survives being drawn at whatever size the badge is.
    ///
    /// Vector first, as artwork that is resolution independent cannot be soft at any size. An
    /// `.icns` is next and not last among the rasters, because it is not one bitmap but a stack of
    /// them drawn for specific sizes, including the small ones a 16 point badge actually uses: it
    /// is the only raster format here that was authored for this exact problem. A layered document
    /// is vector inside, but Bloom has to compose it itself without the system's glass, shadow and
    /// specular passes, so it sits below the flattened `.icns` that projects ship beside it. JPEG
    /// is last, because it cannot hold a transparent corner and because a project that has any of
    /// the others has said something more deliberate with them.
    var tier: Int {
        switch self {
        case .svg: 5
        case .icns: 4
        case .layered: 3
        case .png, .ico: 2
        case .jpeg: 1
        }
    }
}

/// One piece of artwork a repository has, with everything the ranking needs to compare it.
public struct RepoIconCandidate: Sendable, Hashable, Codable {
    /// Absolute. A directory for `layered`, a file for everything else.
    public var path: String
    public var format: RepoIconFormat
    public var origin: RepoIconOrigin
    /// The longest edge of the largest image in the file, in pixels. Zero for vector artwork,
    /// which has no such number and needs none.
    public var pixels: Int
    /// The longer edge over the shorter one, or nil when the file does not state a size at all.
    /// See `shape`, which is the only thing that reads it.
    public var aspect: Double?
    /// How many words the name adds to the plainest name this file could have had, so that a
    /// dressed up name loses to the plain one beside it. See `decoration(ofFileNamed:)`.
    public var decoration: Int

    public init(
        path: String,
        format: RepoIconFormat,
        origin: RepoIconOrigin,
        pixels: Int,
        aspect: Double? = nil,
        decoration: Int = 0
    ) {
        self.path = path
        self.format = format
        self.origin = origin
        self.pixels = pixels
        self.aspect = aspect
        self.decoration = decoration
    }

    /// How well the artwork fits a square tile, in three steps: square, nearly square, and oblong
    /// but not oblong enough to have been refused outright.
    ///
    /// Steps rather than the ratio itself, because the ratio is a measurement and the difference
    /// between 1.00 and 1.02 is the artist's business rather than a reason to prefer one file over
    /// another. Comparing it directly would also let a hair of rounding overrule the name, which
    /// is a real signal, on the strength of one that is not.
    ///
    /// A file that states no size at all counts as square. That is the same reading the aspect
    /// gate already gives it: an SVG which declines to say is taken at its word rather than
    /// guessed about, and guessing here would demote every hand written mark in the world.
    var shape: Int {
        guard let aspect else { return 0 }
        if aspect <= 1.1 { return 0 }
        if aspect <= 1.4 { return 1 }
        return 2
    }

    /// A total order, so the best candidate is a fact rather than whichever the file system
    /// happened to list first.
    ///
    /// In order: what the file is for, then how well the format draws at any size, then how well
    /// it fits a square tile, then the plain name over the dressed up one beside it, then how much
    /// artwork is in it, and finally the path, which decides nothing about quality and exists only
    /// so the answer never changes between runs.
    ///
    /// The shape is above the name because it is a fact about how the badge will look and the name
    /// is a hint about what the author meant. `avatar-boxed.jpg` beside `avatar.jpg` is exactly
    /// that: the plainer name is the uncropped photograph, which would be letterboxed into a band
    /// across the tile, and no rule about names could ever know that the word `boxed` is the one
    /// that means "already cropped square". The picture says it without being asked.
    ///
    /// The name is compared before the size, and the two are arranged so that they cannot argue.
    /// A number in a name is not decoration, so `favicon.png` and `favicon-96x96.png` are equally
    /// plain and the pixels decide between them, which is the existing rule about sizes left
    /// exactly as it was. When they do disagree it is because a word was added rather than a
    /// measurement, and then the plainer name wins however big the other file is: a larger picture
    /// of the wrong artwork is still the wrong artwork.
    public func isBetter(than other: RepoIconCandidate) -> Bool {
        if origin.rank != other.origin.rank { return origin.rank > other.origin.rank }
        if format.tier != other.format.tier { return format.tier > other.format.tier }
        if shape != other.shape { return shape < other.shape }
        if decoration != other.decoration { return decoration < other.decoration }
        if pixels != other.pixels { return pixels > other.pixels }
        let depth = path.components(separatedBy: "/").count
        let otherDepth = other.path.components(separatedBy: "/").count
        if depth != otherDepth { return depth < otherDepth }
        return path < other.path
    }
}
