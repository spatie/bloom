import Foundation

/// The arguments of the tools that act inside a page: which element, which key, what to wait for.
///
/// Read here, in the core, for the reason `BrowserScroll` is: every one of them is a string a
/// model wrote, and what decides whether it is a reference, a key or a timeout is a rule a test
/// can hold. What reaches the page afterwards is a value passed to `callAsyncJavaScript` as an
/// argument, never characters spliced into source. See `BrowserAgentScript`.

/// An element `browser_snapshot` handed out, as `e12`.
///
/// **A number the snapshot issued rather than a selector the caller wrote**, which is the shape
/// agent-browser settled on and for the same reason: a model that has just read an outline can
/// name the button it means without inventing a CSS path that half matches three others. The
/// references live in Bloom's own content world, so the page can neither read them nor move one
/// to point at a different element.
public struct BrowserElementRef: Sendable, Equatable {
    public let number: Int

    public init(number: Int) {
        self.number = number
    }

    /// How it is written in an outline and in a call: `e` and the number.
    public var label: String { "e\(number)" }

    /// Reads `e12`, `@e12` or `12`. The `@` is agent-browser's spelling, and a model that has used
    /// that tool will reach for it.
    public static func parse(_ raw: String?, tool: String) -> Result<BrowserElementRef, PaneRefusal> {
        var text = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else {
            return .failure(
                PaneRefusal(
                    "\(tool) needs a 'ref', which is one of the references browser_snapshot "
                        + "gives each element, such as e3. Take a snapshot first."
                )
            )
        }
        if text.hasPrefix("@") { text.removeFirst() }
        if text.hasPrefix("e") || text.hasPrefix("E") { text.removeFirst() }
        guard let number = Int(text), number > 0, text.allSatisfy(\.isASCIIDigit) else {
            return .failure(
                PaneRefusal(
                    "'\(raw ?? "")' is not a reference browser_snapshot gave out. They look like "
                        + "e3. Take a snapshot and use one from it."
                )
            )
        }
        return .success(BrowserElementRef(number: number))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// What to type into a field, capped.
///
/// A cap because a fill is typed into the owner's page and travels through the permission prompt
/// first, and a prompt holding a megabyte is a prompt nobody reads.
public enum BrowserFillText {
    public static let limit = 10_000

    public static func parse(_ raw: JSONValue?) -> Result<String, PaneRefusal> {
        guard case .string(let text)? = raw else {
            return .failure(
                PaneRefusal(
                    "browser_fill needs a 'text' to put in the field, as a string. Pass an empty "
                        + "string to clear it."
                )
            )
        }
        guard text.count <= limit else {
            return .failure(
                PaneRefusal("'text' is at most \(limit) characters.")
            )
        }
        return .success(text)
    }
}

/// One key press, with the modifiers held down for it.
///
/// **A fixed vocabulary rather than whatever the caller spells**, because what a page receives is
/// a `KeyboardEvent` whose `key`, `code` and `keyCode` all have to agree, and a page that listens
/// for `keyCode === 13` and gets a zero is a press that did nothing and said it worked.
public struct BrowserKey: Sendable, Equatable {
    public struct Modifiers: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
        public static let meta = Modifiers(rawValue: 8)
    }

    /// The DOM's `key`: `Enter`, `ArrowDown`, `a`.
    public let key: String
    /// The DOM's `code`: `Enter`, `ArrowDown`, `KeyA`.
    public let code: String
    /// The legacy `keyCode`, which older pages and a good many date pickers still read.
    public let keyCode: Int
    public let modifiers: Modifiers

    /// Whether the key produces a character, which is what decides whether a press into a text
    /// field also types it.
    public var isCharacter: Bool { key.count == 1 }

    /// The named keys, with their `code` and `keyCode`.
    static let named: [String: (code: String, keyCode: Int)] = [
        "Enter": ("Enter", 13),
        "Tab": ("Tab", 9),
        "Escape": ("Escape", 27),
        "Backspace": ("Backspace", 8),
        "Delete": ("Delete", 46),
        "ArrowUp": ("ArrowUp", 38),
        "ArrowDown": ("ArrowDown", 40),
        "ArrowLeft": ("ArrowLeft", 37),
        "ArrowRight": ("ArrowRight", 39),
        "Home": ("Home", 36),
        "End": ("End", 35),
        "PageUp": ("PageUp", 33),
        "PageDown": ("PageDown", 34),
        " ": ("Space", 32),
    ]

    /// Other spellings a model will reach for, folded onto the DOM's.
    private static let aliases: [String: String] = [
        "return": "Enter", "enter": "Enter", "tab": "Tab", "escape": "Escape", "esc": "Escape",
        "backspace": "Backspace", "delete": "Delete", "del": "Delete",
        "arrowup": "ArrowUp", "up": "ArrowUp", "arrowdown": "ArrowDown", "down": "ArrowDown",
        "arrowleft": "ArrowLeft", "left": "ArrowLeft", "arrowright": "ArrowRight",
        "right": "ArrowRight", "home": "Home", "end": "End", "pageup": "PageUp",
        "pagedown": "PageDown", "space": " ",
    ]

    private static let modifierNames: [String: Modifiers] = [
        "shift": .shift, "control": .control, "ctrl": .control, "alt": .alt, "option": .alt,
        "meta": .meta, "cmd": .meta, "command": .meta,
    ]

    public init(key: String, code: String, keyCode: Int, modifiers: Modifiers = []) {
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Reads `Enter`, `Shift+Tab`, `Meta+a` or a single character.
    public static func parse(_ raw: String?) -> Result<BrowserKey, PaneRefusal> {
        let text = raw ?? ""
        guard !text.isEmpty else {
            return .failure(PaneRefusal("browser_press needs a 'key'. \(vocabulary)"))
        }

        // A lone "+" is the plus key, not an empty chord, so only split when there is more.
        var parts = text.count > 1 ? text.components(separatedBy: "+") : [text]
        if text.count > 1, text.hasSuffix("+") {
            parts.removeLast(2)
            parts.append("+")
        }
        let name = parts.removeLast()

        var modifiers: Modifiers = []
        for part in parts {
            guard let modifier = modifierNames[part.lowercased()] else {
                return .failure(
                    PaneRefusal("'\(part)' is not a modifier Bloom knows. \(vocabulary)")
                )
            }
            modifiers.insert(modifier)
        }

        if name.count == 1, let character = name.first, !character.isNewline {
            if let named = Self.named[name] {
                return .success(BrowserKey(key: name, code: named.code, keyCode: named.keyCode, modifiers: modifiers))
            }
            return .success(character.key(modifiers: modifiers))
        }
        let canonical = Self.named[name] != nil ? name : aliases[name.lowercased()]
        guard let canonical, let named = Self.named[canonical] else {
            return .failure(PaneRefusal("Bloom does not press '\(name)'. \(vocabulary)"))
        }
        return .success(
            BrowserKey(key: canonical, code: named.code, keyCode: named.keyCode, modifiers: modifiers)
        )
    }

    static let vocabulary = """
        A key is one character, or one of Enter, Tab, Escape, Backspace, Delete, ArrowUp, \
        ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown or Space, optionally after \
        Shift+, Control+, Alt+ or Meta+.
        """

    /// What the tool says back, in the words the caller used.
    public var spoken: String {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("Control") }
        if modifiers.contains(.alt) { names.append("Alt") }
        if modifiers.contains(.shift) { names.append("Shift") }
        if modifiers.contains(.meta) { names.append("Meta") }
        names.append(key == " " ? "Space" : key)
        return names.joined(separator: "+")
    }
}

private extension Character {
    /// A printable character as a key: letters and digits get the `code` a physical key would, and
    /// everything else gets none, which is what a page sees from a key it has no layout for.
    func key(modifiers: BrowserKey.Modifiers) -> BrowserKey {
        let text = String(self)
        let upper = text.uppercased()
        if isASCII, isLetter, let scalar = upper.unicodeScalars.first {
            return BrowserKey(key: text, code: "Key\(upper)", keyCode: Int(scalar.value), modifiers: modifiers)
        }
        if isASCII, isNumber, let scalar = unicodeScalars.first {
            return BrowserKey(key: text, code: "Digit\(text)", keyCode: Int(scalar.value), modifiers: modifiers)
        }
        return BrowserKey(key: text, code: "", keyCode: 0, modifiers: modifiers)
    }
}

/// What `browser_wait` waits for, and for how long.
public struct BrowserWait: Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        /// The page has stopped loading. What a call with nothing else in it means.
        case load
        /// An element matching this CSS selector is on the page and visible.
        case selector(String)
        /// This text is in the page's visible text.
        case text(String)
        /// The address contains this.
        case url(String)
    }

    public let condition: Condition
    public let milliseconds: Int

    public static let defaultMilliseconds = 10_000
    /// Thirty seconds. A turn waiting longer than that on one page is a turn the owner is watching
    /// do nothing, and a model that needs longer can call again.
    public static let maximumMilliseconds = 30_000
    public static let minimumMilliseconds = 100

    public init(condition: Condition, milliseconds: Int = BrowserWait.defaultMilliseconds) {
        self.condition = condition
        self.milliseconds = milliseconds
    }

    /// Reads the arguments. At most one of `selector`, `text` and `url`; none is a wait for load.
    public static func parse(
        selector: String?, text: String?, url: String?, timeout: JSONValue?
    ) -> Result<BrowserWait, PaneRefusal> {
        let given = [
            selector.map { Condition.selector($0) },
            text.map { Condition.text($0) },
            url.map { Condition.url($0) },
        ].compactMap { $0 }
        guard given.count <= 1 else {
            return .failure(
                PaneRefusal(
                    "browser_wait waits for one thing at a time: pass 'selector', 'text' or 'url', "
                        + "not several. Call it again for the next."
                )
            )
        }
        let condition = given.first ?? .load
        switch condition {
        case .selector(let value), .text(let value), .url(let value):
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(
                    PaneRefusal("browser_wait was handed an empty string to wait for.")
                )
            }
            guard value.count <= 1_000 else {
                return .failure(PaneRefusal("What browser_wait waits for is at most 1000 characters."))
            }
        case .load:
            break
        }

        switch timeout {
        case .none, .null:
            return .success(BrowserWait(condition: condition))
        case .integer(let seconds):
            return milliseconds(Double(seconds)).map { BrowserWait(condition: condition, milliseconds: $0) }
        case .number(let seconds):
            return milliseconds(seconds).map { BrowserWait(condition: condition, milliseconds: $0) }
        default:
            return .failure(PaneRefusal("'timeout' is a number of seconds."))
        }
    }

    private static func milliseconds(_ seconds: Double) -> Result<Int, PaneRefusal> {
        let value = Int((seconds * 1_000).rounded())
        guard value >= minimumMilliseconds, value <= maximumMilliseconds else {
            return .failure(
                PaneRefusal(
                    "'timeout' is between 0.1 and \(maximumMilliseconds / 1_000) seconds."
                )
            )
        }
        return .success(value)
    }

    /// What the tool says when the wait is over, either way.
    public func report(met: Bool, afterMilliseconds elapsed: Int) -> String {
        let what: String
        switch condition {
        case .load: what = "the page to finish loading"
        case .selector(let selector): what = "an element matching \(selector)"
        case .text(let text): what = "the text \"\(text)\""
        case .url(let url): what = "an address containing \(url)"
        }
        let seconds = String(format: "%.1f", Double(elapsed) / 1_000)
        return met
            ? "Waited \(seconds)s for \(what), and it is there."
            : "Gave up after \(seconds)s waiting for \(what). browser_snapshot or browser_screenshot "
                + "shows what the page has instead."
    }
}
