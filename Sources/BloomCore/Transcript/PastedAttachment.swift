import Foundation

/// An image format a pasteboard can hand over, in the order Bloom would rather have it.
///
/// Order is preference, and preference is about what reaches the agent. PNG is lossless and
/// already compressed, so it is written straight out. JPEG is already compressed too, and
/// re-encoding it would only lose detail. TIFF is neither: it is what the system falls back to
/// when nothing better was put on the board, it is often twenty times the size of the same
/// picture as PNG, and it is the one of the three an agent is unlikely to be able to open.
public enum PastedImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case tiff

    /// The uniform type the pasteboard names it by.
    public var uti: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .tiff: "public.tiff"
        }
    }

    /// What the file is called after the dot. `jpg` rather than `jpeg`, which is what every
    /// camera, every screenshot tool and every save panel on this machine writes.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }

    /// Whether the bytes are worth rewriting before they land in the worktree.
    ///
    /// Only TIFF. See `PastedAttachment.reencoded` for what that trade costs.
    public var isWorthReencoding: Bool { self == .tiff }

    /// The format a rewrite produces. Everything that is already compressed stays as it is.
    public var written: PastedImageFormat { isWorthReencoding ? .png : self }

    /// The best of what one pasteboard item offers, or nil when it offers no picture at all.
    public static func best(of utis: [String]) -> PastedImageFormat? {
        allCases.first { format in utis.contains(format.uti) }
    }
}

/// What a pasteboard is offering, and what an attachment made out of it is called.
///
/// Pure, and in BloomCore, because this is the part of pasting that is a decision rather than a
/// gesture: which of the half dozen flavours on a clipboard is the one the user meant, whether
/// what they meant was a file at all, and what a picture that has never had a name should be
/// called. `ComposerTextView` reads an `NSPasteboard` into `Offer` values and does what comes
/// back; nothing here knows AppKit exists.
public enum PastedAttachment {
    /// One item on a pasteboard, reduced to the two things that decide its fate.
    ///
    /// A clipboard is a list of items and each item is a list of flavours of the same thing.
    /// Copying three files in Finder gives three items; a screenshot gives one item wearing PNG
    /// and TIFF at once.
    public struct Offer: Sendable, Equatable {
        /// The file this item points at, if it points at one.
        public var filePath: String?
        /// The uniform types this item carries data for.
        public var types: [String]

        public init(filePath: String? = nil, types: [String] = []) {
            self.filePath = filePath
            self.types = types
        }

        public var imageFormat: PastedImageFormat? { PastedImageFormat.best(of: types) }
    }

    /// One picture worth reading off the board: which item it is on, and which flavour of it to
    /// ask for.
    public struct Image: Sendable, Equatable {
        public var item: Int
        public var format: PastedImageFormat

        public init(item: Int, format: PastedImageFormat) {
            self.item = item
            self.format = format
        }
    }

    /// What the composer should do with a pasteboard.
    public enum Plan: Sendable, Equatable {
        /// Attach these files, which already exist on this Mac.
        case files([String])
        /// Write these pictures into the worktree, because nothing on the board is a file.
        case images([Image])
        /// None of Bloom's business. The text system pastes it, exactly as it always has.
        case text
    }

    /// Which of the three a clipboard deserves.
    ///
    /// **Files win outright.** A file copied in Finder has a name, a size and a place, and every
    /// one of those is better than the same bytes rewritten under a name Bloom invented. This is
    /// also the CleanShot case: a capture that was saved to disk arrives as a file URL *and* as
    /// PNG data, and attaching the file is what puts the user's own filename on the chip.
    ///
    /// **Pictures win when there is nothing to read.** A screenshot copied rather than saved is
    /// bytes and nothing else, which is the case this whole path exists for.
    ///
    /// **Text wins whenever there is any.** A clipboard carrying words and a picture is a clipboard
    /// somebody filled by selecting a passage, and swallowing the words to attach the illustration
    /// would throw away what they actually copied. Pasting has to keep meaning pasting, so this is
    /// the case that falls through to the text system untouched.
    public static func plan(items: [Offer], hasText: Bool) -> Plan {
        let files = items.compactMap(\.filePath)
        if !files.isEmpty { return .files(files) }

        guard !hasText else { return .text }

        let images = items.enumerated().compactMap { index, item in
            item.imageFormat.map { Image(item: index, format: $0) }
        }
        return images.isEmpty ? .text : .images(images)
    }

    // MARK: - What a picture with no name is called

    /// The name a pasted picture is written under.
    ///
    /// Modelled on what macOS calls a screenshot, so a folder of them sorts by when they were
    /// taken and reads as a date rather than as an id. `Pasted` rather than `Screenshot` because
    /// it is the honest word for something that came off a clipboard, and because a name nobody
    /// could mistake for the user's own file is what makes a chip in the bar self-explanatory.
    ///
    /// Seconds are as fine as the timestamp goes, so two pastes inside one second would earn the
    /// same name. They do not collide on disk, because every attachment is written into its own
    /// six character folder, but two chips reading `Pasted 2026-08-20 at 22.29.20.png` are two
    /// chips the user cannot tell apart. `avoiding` is every name already spoken for, and the
    /// second one becomes `Pasted 2026-08-20 at 22.29.20 2.png`, which is how the Finder counts.
    public static func filename(
        format: PastedImageFormat,
        at date: Date = .now,
        avoiding taken: Set<String> = [],
        timeZone: TimeZone = .current
    ) -> String {
        uniqued("Pasted \(timestamp(date, in: timeZone)).\(format.fileExtension)", avoiding: taken)
    }

    /// The same name with a number on it, when the name is already spoken for.
    ///
    /// Counted the way the Finder counts, before the extension rather than after it, so the file
    /// is still a PNG and still sorts beside the one it was pasted a moment after. Two is the
    /// first number worth printing: the one before it is the name without a number.
    public static func uniqued(_ name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        for counter in 2...999 {
            let candidate = "\(base) \(counter)\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(6))\(suffix)"
    }

    /// The date part of an attachment's name. Public because `BrowserSnapshot` names a file the
    /// same way and the two must agree: a folder of screenshots is sorted by this string, so two
    /// formats would interleave into an order that reads as random.
    public static func timestamp(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        // Fixed locale, because this is a filename rather than something being read aloud: a
        // Persian or Japanese calendar would name the same file differently on two machines and
        // sort it differently in the same folder.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        // Dots rather than colons in the time, for the reason macOS uses them: a colon is a path
        // separator to the Finder and is rewritten behind the user's back.
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
