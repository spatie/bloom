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

    /// The document's layers, bottom first, as absolute paths.
    ///
    /// `icon.json` lists its groups front to back, the way a layers panel does, so the order is
    /// reversed here into the order they have to be drawn in. What the system adds on top of them
    /// (the glass, the shadow and the specular pass) belongs to the compositor and is not
    /// reproduced: this is the artwork, not the finished macOS 26 icon, which is why a flattened
    /// `.icns` beside it outranks it.
    static func layers(ofIconBundle path: String) -> [String] {
        let manifest = (path as NSString).appendingPathComponent("icon.json")
        guard let data = RepoIconDetector.boundedContents(ofFile: manifest, limit: 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]]
        else { return [] }

        var names: [String] = []
        for group in groups {
            guard let layers = group["layers"] as? [[String: Any]] else { continue }
            for layer in layers {
                guard let name = layer["image-name"] as? String, !name.isEmpty else { continue }
                names.append(name)
            }
        }

        return names.reversed().compactMap { name in
            let assets = (path as NSString).appendingPathComponent("Assets/\(name)")
            if FileManager.default.fileExists(atPath: assets) { return assets }
            let loose = (path as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: loose) { return loose }
            return nil
        }
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
