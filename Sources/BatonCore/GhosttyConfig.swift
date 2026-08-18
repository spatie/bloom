import Foundation

/// A colour from a Ghostty config, as the three opaque channels a terminal actually renders.
///
/// Deliberately not an AppKit colour: BatonCore has no UI, and the whole point of reading Ghostty
/// is to reproduce fixed bytes rather than something that shifts with appearance or contrast.
public struct GhosttyColor: Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, `rrggbb`, `#rgb` or `rgb`. Ghostty accepts the hash as optional, and the three
    /// digit form expands each digit to a byte, so `#abc` is `#aabbcc`.
    ///
    /// X11 colour names are valid in Ghostty too but are not understood here: an unparseable
    /// value leaves the key untouched rather than resetting it, so a name falls back to Baton's
    /// own colour instead of to something wrong.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }

        let digits = text.compactMap(\.hexDigitValue)
        guard digits.count == text.count else { return nil }

        switch digits.count {
        // Each digit is doubled, so `#abc` is `#aabbcc`.
        case 3:
            self.init(
                red: UInt8(digits[0] * 17),
                green: UInt8(digits[1] * 17),
                blue: UInt8(digits[2] * 17)
            )
        case 6:
            self.init(
                red: UInt8(digits[0] * 16 + digits[1]),
                green: UInt8(digits[2] * 16 + digits[3]),
                blue: UInt8(digits[4] * 16 + digits[5])
            )
        default:
            return nil
        }
    }
}

/// Which half of a `theme = light:…,dark:…` pair applies.
public enum GhosttyAppearance: String, Sendable, Hashable {
    case light
    case dark
}

/// The slice of Ghostty's configuration Baton's terminal can honour.
///
/// Every colour is optional and `nil` means "Ghostty said nothing about this", which is what lets
/// a machine with no Ghostty config keep Baton's own appearance untouched.
public struct GhosttyTheme: Sendable, Hashable {
    public var background: GhosttyColor?
    public var foreground: GhosttyColor?
    public var cursorColor: GhosttyColor?
    public var cursorTextColor: GhosttyColor?
    public var selectionBackground: GhosttyColor?
    public var selectionForeground: GhosttyColor?
    /// Only the slots the config named. Ghostty allows 0...255; SwiftTerm is handed 0...15, so
    /// the rest is kept but unused rather than being rejected as an error.
    public var palette: [Int: GhosttyColor] = [:]
    public var fontFamily: String?
    public var fontSize: Double?

    public init() {}

    public var isEmpty: Bool {
        background == nil
            && foreground == nil
            && cursorColor == nil
            && cursorTextColor == nil
            && selectionBackground == nil
            && selectionForeground == nil
            && palette.isEmpty
            && fontFamily == nil
            && fontSize == nil
    }

    /// The sixteen ANSI slots, Ghostty's own defaults wherever the config was silent.
    ///
    /// Filling the gaps from Ghostty rather than from Baton's palette matters: a user who
    /// overrides one slot expects the other fifteen to look like their terminal, not like a
    /// second theme spliced in behind it.
    public func ansiColors() -> [GhosttyColor] {
        (0..<16).map { palette[$0] ?? Self.defaultPalette[$0] }
    }

    /// Ghostty's built-in sixteen, from `Name.default` in `src/terminal/color.zig`.
    public static let defaultPalette: [GhosttyColor] = [
        GhosttyColor(red: 0x1D, green: 0x1F, blue: 0x21),
        GhosttyColor(red: 0xCC, green: 0x66, blue: 0x66),
        GhosttyColor(red: 0xB5, green: 0xBD, blue: 0x68),
        GhosttyColor(red: 0xF0, green: 0xC6, blue: 0x74),
        GhosttyColor(red: 0x81, green: 0xA2, blue: 0xBE),
        GhosttyColor(red: 0xB2, green: 0x94, blue: 0xBB),
        GhosttyColor(red: 0x8A, green: 0xBE, blue: 0xB7),
        GhosttyColor(red: 0xC5, green: 0xC8, blue: 0xC6),
        GhosttyColor(red: 0x66, green: 0x66, blue: 0x66),
        GhosttyColor(red: 0xD5, green: 0x4E, blue: 0x53),
        GhosttyColor(red: 0xB9, green: 0xCA, blue: 0x4A),
        GhosttyColor(red: 0xE7, green: 0xC5, blue: 0x47),
        GhosttyColor(red: 0x7A, green: 0xA6, blue: 0xDA),
        GhosttyColor(red: 0xC3, green: 0x97, blue: 0xD8),
        GhosttyColor(red: 0x70, green: 0xC0, blue: 0xB1),
        GhosttyColor(red: 0xEA, green: 0xEA, blue: 0xEA),
    ]
}

/// Ghostty's `key = value` file format.
public enum GhosttyConfigParser {
    public struct Entry: Sendable, Hashable {
        public var key: String
        /// Empty means the line reset the key, which in Ghostty restores its default.
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Order is preserved, because Ghostty resolves repeated keys by last-one-wins.
    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A `#` only comments out a line when it is the first thing on it. Ghostty's own
            // template file warns about exactly this, because `background = #123abc` would
            // otherwise read as a comment and the config would silently do nothing.
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            guard let separator = line.firstIndex(of: "=") else {
                // A bare key with no `=` is Ghostty's other way of saying "reset this".
                return Entry(key: line, value: "")
            }

            return Entry(
                key: String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces),
                value: String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
            )
        }
    }
}

/// Folds parsed entries and any referenced theme into one `GhosttyTheme`.
public enum GhosttyConfigResolver {
    /// - Parameters:
    ///   - sources: file contents, LOWEST precedence first.
    ///   - appearance: picks a side of `theme = light:…,dark:…`.
    ///   - themeText: hands back a theme file's contents for a theme name, or nil if there is none.
    public static func resolve(
        sources: [String],
        appearance: GhosttyAppearance,
        themeText: (String) -> String? = { _ in nil }
    ) -> GhosttyTheme {
        var explicit = GhosttyTheme()
        var themeSetting: String?

        for source in sources {
            for entry in GhosttyConfigParser.parse(source) {
                if entry.key == "theme" {
                    themeSetting = entry.value.isEmpty ? nil : entry.value
                    continue
                }
                apply(entry, to: &explicit)
            }
        }

        guard let name = themeSetting.flatMap({ themeName($0, appearance: appearance) }),
              let text = themeText(name) else {
            return explicit
        }

        // The theme is the floor, never the ceiling. Ghostty documents that "any additional colors
        // specified via background, foreground, palette, etc. will override the colors specified in
        // the theme", and says so without qualifying it by order, so layering explicit values on
        // top afterwards is closer to Ghostty than replaying both streams in file order would be.
        var resolved = GhosttyTheme()
        for entry in GhosttyConfigParser.parse(text) where entry.key != "theme" {
            apply(entry, to: &resolved)
        }
        merge(explicit, into: &resolved)
        return resolved
    }

    /// The theme to load, resolving Ghostty's `light:<name>,dark:<name>` pair form. Whitespace is
    /// trimmed and the two halves may appear in either order, both of which Ghostty documents.
    public static func themeName(_ setting: String, appearance: GhosttyAppearance) -> String? {
        let parts = setting.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let pairs = parts.compactMap { part -> (GhosttyAppearance, String)? in
            guard let separator = part.firstIndex(of: ":") else { return nil }
            let side = String(part[part.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let name = String(part[part.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard let appearance = GhosttyAppearance(rawValue: side.lowercased()), !name.isEmpty else {
                return nil
            }
            return (appearance, name)
        }

        // Ghostty requires both sides to be present for the pair form, so anything else is a plain
        // theme name. Windows paths are why the check is "both sides parsed", not "contains a
        // colon": `theme = C:\themes\mine` is a path, not a light/dark pair.
        guard pairs.count == parts.count, pairs.count > 1 else {
            return setting.isEmpty ? nil : setting
        }
        return pairs.first { $0.0 == appearance }?.1
    }

    private static func apply(_ entry: GhosttyConfigParser.Entry, to theme: inout GhosttyTheme) {
        // An empty value is Ghostty's reset, so it has to clear rather than be ignored: that is the
        // only way a later file can undo a colour an earlier one set.
        let reset = entry.value.isEmpty

        switch entry.key {
        case "background":
            theme.background = reset ? nil : GhosttyColor(hex: entry.value) ?? theme.background
        case "foreground":
            theme.foreground = reset ? nil : GhosttyColor(hex: entry.value) ?? theme.foreground
        case "cursor-color":
            theme.cursorColor = reset ? nil : GhosttyColor(hex: entry.value) ?? theme.cursorColor
        case "cursor-text":
            theme.cursorTextColor = reset
                ? nil
                : GhosttyColor(hex: entry.value) ?? theme.cursorTextColor
        case "selection-background":
            theme.selectionBackground = reset
                ? nil
                : GhosttyColor(hex: entry.value) ?? theme.selectionBackground
        case "selection-foreground":
            theme.selectionForeground = reset
                ? nil
                : GhosttyColor(hex: entry.value) ?? theme.selectionForeground
        case "font-family":
            // First one wins, unlike every other key here. Repeating `font-family` in Ghostty
            // declares fallbacks rather than replacing the choice, and the first is the primary
            // face, so last-one-wins would render a user's fallback and never their font.
            if reset {
                theme.fontFamily = nil
            } else if theme.fontFamily == nil {
                theme.fontFamily = entry.value
            }
        case "font-size":
            theme.fontSize = reset ? nil : Double(entry.value) ?? theme.fontSize
        case "palette":
            guard !reset else {
                theme.palette.removeAll()
                return
            }
            guard let separator = entry.value.firstIndex(of: "=") else { return }
            let index = Int(
                entry.value[entry.value.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            )
            let color = GhosttyColor(
                hex: String(entry.value[entry.value.index(after: separator)...])
            )
            // Out of range or unparseable entries are dropped the way Ghostty drops them: it logs
            // the error and carries on rather than refusing the whole file.
            guard let index, (0...255).contains(index), let color else { return }
            theme.palette[index] = color
        default:
            break
        }
    }

    private static func merge(_ overlay: GhosttyTheme, into base: inout GhosttyTheme) {
        base.background = overlay.background ?? base.background
        base.foreground = overlay.foreground ?? base.foreground
        base.cursorColor = overlay.cursorColor ?? base.cursorColor
        base.cursorTextColor = overlay.cursorTextColor ?? base.cursorTextColor
        base.selectionBackground = overlay.selectionBackground ?? base.selectionBackground
        base.selectionForeground = overlay.selectionForeground ?? base.selectionForeground
        base.fontFamily = overlay.fontFamily ?? base.fontFamily
        base.fontSize = overlay.fontSize ?? base.fontSize
        base.palette.merge(overlay.palette) { _, explicit in explicit }
    }
}

/// Finds Ghostty's files on disk and turns them into a `GhosttyTheme`.
public enum GhosttyConfigLoader {
    /// Config files, LOWEST precedence first.
    ///
    /// Ghostty's `Config.loadDefaultFiles` loads the XDG path first and the macOS Application
    /// Support path second, and a later assignment wins, so **Application Support wins**. Its
    /// source comments it as "Load XDG first", and `ghostty(5)` says the Application Support
    /// location "takes precedence over the XDG environment locations". Both files are loaded, not
    /// just the first one found, which is what makes this user's split config work: the cream
    /// background comes from Application Support and the green palette slot from `~/.config`.
    ///
    /// Within each directory the legacy `config` name is loaded before `config.ghostty`, matching
    /// the order Ghostty loads them when a user has both.
    public static func configPaths(
        home: String = NSHomeDirectory(),
        xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    ) -> [String] {
        let xdg = xdgConfigHome.flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        return [
            "\(xdg)/ghostty/config",
            "\(xdg)/ghostty/config.ghostty",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ]
    }

    /// Where a `theme = <name>` is looked up, first match wins. Ghostty searches the user's own
    /// themes directory before the ones it ships, so a user can shadow a bundled theme.
    public static func themeDirectories(
        home: String = NSHomeDirectory(),
        xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
        resources: [String] = resourceThemeDirectories
    ) -> [String] {
        let xdg = xdgConfigHome.flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        return ["\(xdg)/ghostty/themes"] + resources
    }

    /// Ghostty ships its themes inside its own bundle, so there is nothing to find if it is not
    /// installed. Only the two places macOS actually puts an app are checked.
    public static let resourceThemeDirectories = [
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        "\(NSHomeDirectory())/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ]

    /// The user's effective Ghostty appearance, or nil when Ghostty is not configured on this
    /// machine at all. Nil is the signal to leave Baton's own terminal colours alone.
    public static func load(
        appearance: GhosttyAppearance,
        paths: [String] = configPaths(),
        themeDirectories: [String] = themeDirectories()
    ) -> GhosttyTheme? {
        let sources = paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        guard !sources.isEmpty else { return nil }

        let theme = GhosttyConfigResolver.resolve(sources: sources, appearance: appearance) { name in
            themeText(named: name, in: themeDirectories)
        }
        return theme.isEmpty ? nil : theme
    }

    /// A theme by name, or by absolute path, which Ghostty also accepts.
    public static func themeText(named name: String, in directories: [String]) -> String? {
        if name.hasPrefix("/") {
            return try? String(contentsOfFile: name, encoding: .utf8)
        }
        // A theme name may not contain path separators in Ghostty, and honouring one here would
        // let a config file reach anywhere on disk.
        guard !name.contains("/") else { return nil }

        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(name)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        }
        return nil
    }
}
