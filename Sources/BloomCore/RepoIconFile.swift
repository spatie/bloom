import Foundation

/// What a file on disk really is, read from its own first bytes.
///
/// The extension is a claim, not a fact. A `favicon.png` that is an HTML error page, a `logo.svg`
/// that is a truncated download and an `icon.ico` that is zero bytes are all things a checkout
/// genuinely contains, and every one of them would otherwise reach the sidebar as a project with
/// no visible mark and no way to tell why. So the format is confirmed from the header, and the
/// size is read from the same place.
///
/// Headers only. Nothing here decodes an image: the dimensions of these formats are stated in the
/// first few bytes or in a table of contents, so measuring a 300 KB `.icns` costs four reads of
/// eight bytes rather than a megabyte of pixels. That also keeps the whole detector in the core,
/// where `./test-core.sh` can reach it, with no dependency on ImageIO or AppKit.
enum RepoIconFile {
    struct Measurement: Sendable, Hashable {
        var format: RepoIconFormat
        /// The longest edge of the largest image inside, or zero for vector artwork.
        var pixels: Int
        /// The longer edge over the shorter one, or nil when the file does not say.
        ///
        /// A mark is roughly square. A picture that is four times wider than it is tall is a
        /// wordmark or a banner, and there is nothing a 16 point tile can do with one but shrink
        /// it to a sliver. Only an SVG can decline to answer: it may state no size at all, in
        /// which case it is taken at its word rather than guessed about.
        var aspect: Double?

        init(format: RepoIconFormat, pixels: Int, aspect: Double? = 1) {
            self.format = format
            self.pixels = pixels
            self.aspect = aspect
        }
    }

    static func measure(_ path: String) -> Measurement? {
        let lower = path.lowercased()
        if lower.hasSuffix(".icon") { return measureIconBundle(path) }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Read by what the bytes say rather than by what the name says, so a `.png` holding an ICO
        // is measured correctly instead of refused. Which of these is even attempted still follows
        // the extension, because a file called `favicon.svg` that turns out to be a PNG has a
        // problem the detector should not paper over.
        if lower.hasSuffix(".png") { return measurePNG(handle) }
        if lower.hasSuffix(".ico") { return measureICO(handle) }
        if lower.hasSuffix(".icns") { return measureICNS(handle) }
        if lower.hasSuffix(".svg") { return measureSVG(handle) }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return measureJPEG(handle) }
        return nil
    }

    // MARK: - PNG

    /// The magic number, then a first chunk that must be `IHDR` and states the dimensions.
    private static func measurePNG(_ handle: FileHandle) -> Measurement? {
        guard let header = read(handle, at: 0, count: 24), header.count == 24 else { return nil }
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(header[0..<8]) == magic else { return nil }
        guard Array(header[12..<16]) == Array("IHDR".utf8) else { return nil }

        let width = Int(be32(header, at: 16))
        let height = Int(be32(header, at: 20))
        guard width > 0, height > 0 else { return nil }
        return Measurement(
            format: .png,
            pixels: max(width, height),
            aspect: Double(max(width, height)) / Double(min(width, height))
        )
    }

    // MARK: - ICO

    /// A six byte header and then one sixteen byte entry per image, each stating its own size.
    ///
    /// The largest is the answer, because an `.ico` is a bundle of sizes and the file as a whole is
    /// as good as its best one. A zero in the width or height byte means 256, which is how the
    /// format squeezed 256 into a byte that stops at 255.
    private static func measureICO(_ handle: FileHandle) -> Measurement? {
        guard let header = read(handle, at: 0, count: 6), header.count == 6 else { return nil }
        guard le16(header, at: 0) == 0, le16(header, at: 2) == 1 else { return nil }
        let count = Int(le16(header, at: 4))
        guard count > 0, count < 512 else { return nil }

        guard let directory = read(handle, at: 6, count: count * 16),
              directory.count == count * 16
        else { return nil }

        var largest = 0
        for index in 0..<count {
            let width = Int(directory[index * 16])
            let height = Int(directory[index * 16 + 1])
            largest = max(largest, max(width == 0 ? 256 : width, height == 0 ? 256 : height))
        }
        guard largest > 0 else { return nil }
        return Measurement(format: .ico, pixels: largest)
    }

    // MARK: - JPEG

    /// `FFD8`, then a chain of segments, each stating its own length, until one of them is a frame
    /// header and states the dimensions.
    ///
    /// Walked by length rather than searched for, because `FFC0` is two bytes that occur inside
    /// EXIF data, inside a colour profile and inside a thumbnail as often as they occur as a
    /// marker. A photograph puts a great deal in front of its first frame, so the walk seeks from
    /// segment to segment and reads four bytes at each: a 4 MB photograph costs a handful of them.
    ///
    /// Nothing after the scan states a size, so a file whose frame header is missing measures as
    /// nothing rather than being guessed at, which is what a truncated download looks like.
    private static func measureJPEG(_ handle: FileHandle) -> Measurement? {
        guard let start = read(handle, at: 0, count: 2), start == [0xFF, 0xD8] else { return nil }
        let end = (try? handle.seekToEnd()) ?? 0

        var offset: UInt64 = 2
        while offset + 4 <= end {
            guard let head = read(handle, at: offset, count: 4), head.count == 4 else { return nil }
            guard head[0] == 0xFF else { return nil }
            let marker = head[1]

            // Padding between segments is written as a run of 0xFF.
            if marker == 0xFF { offset += 1; continue }
            // The markers that carry nothing, so there is no length to skip by.
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { offset += 2; continue }
            // The scan is the pixels, and the end is the end.
            if marker == 0xDA || marker == 0xD9 { return nil }

            if frameMarkers.contains(marker) {
                guard let frame = read(handle, at: offset + 4, count: 5), frame.count == 5
                else { return nil }
                let height = Int(frame[1]) << 8 | Int(frame[2])
                let width = Int(frame[3]) << 8 | Int(frame[4])
                guard width > 0, height > 0 else { return nil }
                return Measurement(
                    format: .jpeg,
                    pixels: max(width, height),
                    aspect: Double(max(width, height)) / Double(min(width, height))
                )
            }

            let length = UInt64(Int(head[2]) << 8 | Int(head[3]))
            guard length >= 2 else { return nil }
            offset += 2 + length
        }
        return nil
    }

    /// The markers that begin a frame and therefore state its width and height. Baseline,
    /// progressive, lossless and the arithmetic coded spellings of each. `C4`, `C8` and `CC` sit
    /// in the same range and are a Huffman table, an extension and an arithmetic table: they carry
    /// no dimensions and are skipped by length like any other segment.
    private static let frameMarkers: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    ]

    // MARK: - ICNS

    /// `icns`, a total length, and then a chain of typed chunks whose four letter names each mean
    /// a particular size. Walked by seeking from length to length, so the pixels are never read.
    private static func measureICNS(_ handle: FileHandle) -> Measurement? {
        guard let header = read(handle, at: 0, count: 8), header.count == 8 else { return nil }
        guard Array(header[0..<4]) == Array("icns".utf8) else { return nil }

        let declared = UInt64(be32(header, at: 4))
        let actual = (try? handle.seekToEnd()) ?? 0
        // A truncated download states a length the file does not have. Walking it anyway would
        // read past the end of every chunk it names.
        let end = min(declared, actual)
        guard end > 8 else { return nil }

        var offset: UInt64 = 8
        var largest = 0
        while offset + 8 <= end {
            guard let chunk = read(handle, at: offset, count: 8), chunk.count == 8 else { break }
            let type = String(decoding: chunk[0..<4], as: UTF8.self)
            let length = UInt64(be32(chunk, at: 4))
            guard length >= 8, offset + length <= end else { break }
            if let size = icnsSizes[type] { largest = max(largest, size) }
            offset += length
        }
        guard largest > 0 else { return nil }
        return Measurement(format: .icns, pixels: largest)
    }

    /// The chunk types that carry artwork, and the square they are drawn at.
    ///
    /// Only the types that hold an image: a mask (`s8mk` and its relatives) says nothing about
    /// whether there is anything to draw, and a `TOC ` or a `info` chunk is bookkeeping. An
    /// unknown type is ignored rather than guessed at, so a file with nothing but unknown chunks
    /// measures as nothing and is refused.
    private static let icnsSizes: [String: Int] = [
        "ICON": 32, "ICN#": 32,
        "icm#": 16, "icm4": 16, "icm8": 16,
        "ics#": 16, "ics4": 16, "ics8": 16, "is32": 16, "icp4": 16, "ic04": 16,
        "icl4": 32, "icl8": 32, "il32": 32, "icp5": 32, "ic05": 32, "ic11": 32,
        "sb24": 24, "icsb": 36,
        "ich#": 48, "ich4": 48, "ich8": 48, "ih32": 48, "SB24": 48,
        "icp6": 64, "ic12": 64, "icsB": 64,
        "it32": 128, "ic07": 128,
        "ic08": 256, "ic13": 256,
        "ic09": 512, "ic14": 512,
        "ic10": 1024,
    ]

    // MARK: - SVG

    /// XML with an `svg` element in it, which is as much as can be settled without a parser and is
    /// enough to keep out the two things that turn up wearing the extension: an HTML error page
    /// saved by a failed download, and a half written file with no root element at all.
    ///
    /// Only the head of the file is read. A real SVG opens its root element within a comment or two
    /// of the top, and anything that needs more than this much preamble to get there is not one.
    private static func measureSVG(_ handle: FileHandle) -> Measurement? {
        guard let head = read(handle, at: 0, count: 16 * 1024), !head.isEmpty else { return nil }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        guard let start = text.range(of: "<svg"), !text.contains("<html") else { return nil }

        let tail = text[start.upperBound...]
        let tag = String(tail.prefix(while: { $0 != ">" }))
        return Measurement(format: .svg, pixels: 0, aspect: aspect(ofSVGTag: tag))
    }

    /// The proportions of an SVG, from its `viewBox` or from its own width and height.
    ///
    /// The `viewBox` first, because it is the one that describes the drawing: `width` and `height`
    /// are the size the document asks to be laid out at, are frequently a percentage, and are
    /// frequently absent. Nil when neither says anything usable, which is a real answer and not a
    /// failure: plenty of perfectly good marks state only a `viewBox`, and plenty state nothing.
    private static func aspect(ofSVGTag tag: String) -> Double? {
        if let box = attribute("viewbox", in: tag) {
            let numbers = box
                .components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
                .compactMap(Double.init)
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                return max(numbers[2], numbers[3]) / min(numbers[2], numbers[3])
            }
        }
        guard let width = length(attribute("width", in: tag)),
              let height = length(attribute("height", in: tag))
        else { return nil }
        return max(width, height) / min(width, height)
    }

    /// A CSS length, as far as one can be compared with another. A percentage is not a size, and
    /// units are only comparable when both sides carry the same one, so anything exotic is refused
    /// rather than mixed with a plain number.
    private static func length(_ value: String?) -> Double? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              !value.hasSuffix("%") else { return nil }
        for unit in ["px", "pt"] where value.hasSuffix(unit) {
            value = String(value.dropLast(unit.count))
        }
        guard let number = Double(value), number > 0 else { return nil }
        return number
    }

    /// One attribute out of an already lowercased opening tag.
    private static func attribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            guard let range = tag.range(of: "\(name)=\(quote)") else { continue }
            let rest = tag[range.upperBound...]
            guard let end = rest.firstIndex(of: Character(quote)) else { continue }
            return String(rest[..<end])
        }
        return nil
    }

    // MARK: - Icon Composer documents

    /// A macOS 26 `.icon` document: a directory holding `icon.json` and the layers it names.
    ///
    /// Measured as valid only when the layers it names are actually there, because the interesting
    /// failure is a document committed without its `Assets` folder, which is a directory that
    /// parses perfectly and draws nothing.
    private static func measureIconBundle(_ path: String) -> Measurement? {
        guard !layers(ofIconBundle: path).isEmpty else { return nil }
        // Square by construction: an Icon Composer document draws on one canvas of a fixed shape.
        return Measurement(format: .layered, pixels: 0)
    }

    /// The document's layers, bottom first, each with the colour the document paints it in.
    ///
    /// `icon.json` lists its groups front to back, the way a layers panel does, so the order is
    /// reversed here into the order they have to be drawn in.
    ///
    /// THE ARTWORK IS USUALLY A SILHOUETTE, AND THE COLOUR IS IN THIS FILE. A layer's `fill`
    /// REPLACES the artwork's own colours, so an Icon Composer document written the ordinary way
    /// holds five black shapes and five fills. Reading the paths and ignoring the fills, which is
    /// what this used to do, drew a project's mark as a black tile: Bloom's own document does
    /// exactly that, and it was only ever invisible because the flattened `.icns` beside it
    /// outranked the document and was drawn instead.
    ///
    /// What the system adds on top of the layers (the glass, the shadow and the specular pass)
    /// still belongs to the compositor and is still not reproduced. That is why a flattened
    /// `.icns` beside a document goes on outranking it: this is the artwork in its own colours,
    /// not the finished macOS 26 icon.
    static func layers(ofIconBundle path: String) -> [RepoIconLayer] {
        let manifest = (path as NSString).appendingPathComponent("icon.json")
        guard let data = RepoIconDetector.boundedContents(ofFile: manifest, limit: 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]]
        else { return [] }

        var described: [(name: String, fill: RepoIconLayerFill, opacity: Double)] = []
        for group in groups {
            guard let layers = group["layers"] as? [[String: Any]] else { continue }
            for layer in layers {
                guard let name = layer["image-name"] as? String, !name.isEmpty else { continue }
                // A hidden layer is one the author switched off in Icon Composer. It is still in
                // the file, and drawing it would show something the finished icon does not.
                if layer["hidden"] as? Bool == true { continue }
                described.append((
                    name,
                    fill(from: layer["fill"]),
                    (layer["opacity"] as? Double).map { max(0, min(1, $0)) } ?? 1
                ))
            }
        }

        return described.reversed().compactMap { layer in
            let assets = (path as NSString).appendingPathComponent("Assets/\(layer.name)")
            if FileManager.default.fileExists(atPath: assets) {
                return RepoIconLayer(path: assets, fill: layer.fill, opacity: layer.opacity)
            }
            let loose = (path as NSString).appendingPathComponent(layer.name)
            if FileManager.default.fileExists(atPath: loose) {
                return RepoIconLayer(path: loose, fill: layer.fill, opacity: layer.opacity)
            }
            return nil
        }
    }

    /// One layer's `fill` key, or `.artwork` when it has none and the SVG is a picture rather than
    /// a silhouette.
    ///
    /// `blend-mode` and `specular` are read past on purpose. Both describe how the system's own
    /// passes treat the layer, and neither of those passes happens here, so honouring half of the
    /// pair would move a colour away from the artwork rather than towards the finished icon.
    private static func fill(from value: Any?) -> RepoIconLayerFill {
        if let text = value as? String {
            return colour(text).map(RepoIconLayerFill.solid) ?? .artwork
        }
        guard let object = value as? [String: Any] else { return .artwork }

        if let stops = object["linear-gradient"] as? [String], stops.count >= 2,
           let from = colour(stops[0]), let to = colour(stops[1]) {
            // Unit coordinates of the canvas, y running down from the top. Icon Composer omits the
            // orientation for the plain vertical case, which is the default named here.
            let orientation = object["orientation"] as? [String: Any]
            return .linearGradient(
                from: from,
                to: to,
                start: point(orientation?["start"], fallbackY: 0),
                stop: point(orientation?["stop"], fallbackY: 1)
            )
        }

        // Icon Composer's "automatic gradient" derives two stops from one colour by a rule Apple
        // does not publish. One flat colour is wrong by a shade and right about the hue, which is
        // the half that matters at 16 points.
        if let single = object["automatic-gradient"] as? String, let only = colour(single) {
            return .solid(only)
        }
        return .artwork
    }

    private static func point(_ value: Any?, fallbackY: Double) -> RepoIconLayerPoint {
        guard let object = value as? [String: Any] else {
            return RepoIconLayerPoint(x: 0.5, y: fallbackY)
        }
        return RepoIconLayerPoint(
            x: object["x"] as? Double ?? 0.5,
            y: object["y"] as? Double ?? fallbackY
        )
    }

    /// `srgb:r,g,b,a` and its neighbours, or a hex string.
    ///
    /// The colour space prefix is read and discarded. Naming Display P3 and drawing it as sRGB is
    /// a small error in saturation on a wide gamut display; refusing the colour is a black tile,
    /// which is the failure this whole path exists to stop.
    static func colour(_ text: String) -> RepoIconColour? {
        if let hex = HexColor(hex: text) {
            return RepoIconColour(
                red: Double(hex.red) / 255,
                green: Double(hex.green) / 255,
                blue: Double(hex.blue) / 255,
                alpha: 1
            )
        }
        guard let separator = text.lastIndex(of: ":") else { return nil }
        let channels = text[text.index(after: separator)...]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard channels.count >= 3 else { return nil }
        return RepoIconColour(
            red: channels[0],
            green: channels[1],
            blue: channels[2],
            alpha: channels.count > 3 ? channels[3] : 1
        )
    }

    // MARK: - Bytes

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count) else { return nil }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    private static func be32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func le16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }
}

// MARK: - What a layered document says about one of its layers

/// One layer of an Icon Composer document: where the artwork is, and what colour to paint it.
///
/// A separate type rather than a path, because the two halves are useless apart. The SVG is a
/// silhouette in the ordinary case and the colour is the whole of the drawing.
public struct RepoIconLayer: Sendable, Hashable {
    /// Absolute path to the layer's artwork.
    public var path: String
    public var fill: RepoIconLayerFill
    /// `icon.json`'s `opacity`, clamped, defaulting to fully opaque.
    public var opacity: Double

    public init(path: String, fill: RepoIconLayerFill = .artwork, opacity: Double = 1) {
        self.path = path
        self.fill = fill
        self.opacity = opacity
    }
}

/// What replaces a layer's own colours.
public enum RepoIconLayerFill: Sendable, Hashable {
    /// No `fill` key at all. The artwork is a picture and is drawn as it is, which is the case a
    /// hand-written document or an exported one with baked colours lands in.
    case artwork
    case solid(RepoIconColour)
    /// Two stops down a line, each end in unit coordinates of the canvas with y running down from
    /// the top, which is how Icon Composer writes an `orientation`.
    case linearGradient(
        from: RepoIconColour,
        to: RepoIconColour,
        start: RepoIconLayerPoint,
        stop: RepoIconLayerPoint
    )
}

/// A colour a layered document names, as unit channels.
///
/// Doubles rather than `HexColor`'s bytes, because `icon.json` writes fractions and carries an
/// alpha, and because nothing in the core has a colour type with either.
public struct RepoIconColour: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A point in unit coordinates of the icon's canvas, y running down from the top.
///
/// Not `CGPoint`, so that the detector goes on being a thing `./test-core.sh` can reach without
/// any part of the drawing stack under it.
public struct RepoIconLayerPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
