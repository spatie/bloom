import Foundation

/// What `browser_snapshot` hands back: the elements of a page a model can read and act on, each
/// with a reference.
///
/// Rendered the way agent-browser renders its snapshot, one element a line, because that is the
/// shape a model has already seen work:
///
///     - heading "Prompt more, merge more" [e1] level=1
///     - link "Docs" [e3] -> /docs
///     - textbox "Email" [e7] type=email value="freek@example.test"
///     - button "Download" [e9] (offscreen)
///
/// Parsed from the plain strings `BrowserAgentScript.snapshot` returns rather than from whatever
/// the page produced, so every field that reaches a model has been through a `String` and a cap
/// here, and a row that does not have the expected shape is dropped rather than guessed at.
public struct BrowserPageOutline: Sendable, Equatable {
    public struct Element: Sendable, Equatable {
        public var ref: BrowserElementRef
        public var role: String
        public var name: String
        public var value: String
        public var detail: String
        public var flags: [String]

        public init(
            ref: BrowserElementRef, role: String, name: String, value: String = "",
            detail: String = "", flags: [String] = []
        ) {
            self.ref = ref
            self.role = role
            self.name = name
            self.value = value
            self.detail = detail
            self.flags = flags
        }

        /// One line of the outline.
        ///
        /// The name and value are quoted with their quotes and line breaks escaped, so a page
        /// cannot end its own line early and start a line that reads as another element.
        public var line: String {
            var line = "- \(role)"
            if !name.isEmpty { line += " \(Self.quote(name))" }
            line += " [\(ref.label)]"
            if !detail.isEmpty {
                line += role == "link" ? " -> \(Self.flatten(detail))" : " \(Self.flatten(detail))"
            }
            if !value.isEmpty { line += " value=\(Self.quote(value))" }
            if !flags.isEmpty { line += " (\(flags.joined(separator: ", ")))" }
            return line
        }

        private static func quote(_ text: String) -> String {
            let escaped = flatten(text)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        private static func flatten(_ text: String) -> String {
            text.components(separatedBy: .newlines).joined(separator: " ")
        }
    }

    public var elements: [Element]
    /// How many the page had, which is more than `elements` when the limit cut it.
    public var total: Int

    public init(elements: [Element], total: Int) {
        self.elements = elements
        self.total = total
    }

    /// The most elements one snapshot describes. A page with thousands of links is a page whose
    /// outline would fill a turn, and the ones a model needs are almost always near the top or
    /// reached by scrolling.
    public static let limit = 400
    /// The longest a name or value may be.
    public static let nameLimit = 160

    /// Reads the `{ rows, total }` the script answers with. Nil for anything else, which is a page
    /// that navigated away under the call.
    public static func read(_ value: Any?) -> BrowserPageOutline? {
        guard let object = value as? [String: Any], let rows = object["rows"] as? [String] else {
            return nil
        }
        let total = (object["total"] as? NSNumber)?.intValue ?? rows.count / 6
        var elements: [Element] = []
        var index = 0
        while index + 5 < rows.count, elements.count < limit {
            defer { index += 6 }
            guard let number = Int(rows[index]), number > 0 else { continue }
            let role = rows[index + 1]
            guard !role.isEmpty, role.count <= 40, role.allSatisfy({ $0.isLetter }) else { continue }
            elements.append(
                Element(
                    ref: BrowserElementRef(number: number),
                    role: role,
                    name: String(rows[index + 2].prefix(nameLimit)),
                    value: String(rows[index + 3].prefix(nameLimit)),
                    detail: String(rows[index + 4].prefix(nameLimit * 3)),
                    flags: rows[index + 5].split(separator: ",").map(String.init).filter {
                        $0.count <= 20 && $0.allSatisfy(\.isLetter)
                    }
                )
            )
        }
        return BrowserPageOutline(elements: elements, total: max(total, elements.count))
    }

    /// The outline as the model reads it, before it goes into its untrusted envelope.
    public var rendered: String {
        guard !elements.isEmpty else {
            return "(nothing on this page can be read as an element: no headings, links, buttons or fields are visible)"
        }
        var lines = elements.map(\.line)
        if total > elements.count {
            lines.append(
                "(\(total - elements.count) more elements are not listed. Scroll and take another "
                    + "snapshot, or use browser_text.)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
