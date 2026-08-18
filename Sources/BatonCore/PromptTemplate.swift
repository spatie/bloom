import Foundation

/// What one render produced, and what it could not resolve.
///
/// The two failure lists are kept apart because they mean different things to the person editing a
/// template. A name Baton has never heard of is almost always a typo, and it is handed back in the
/// text so the mistake is visible in the transcript rather than swallowed. A name Baton knows but
/// has nothing to say about is a fact about this workspace, not about the template, so it renders
/// as nothing and only the caller is told.
public struct PromptRender: Sendable, Hashable {
    public var text: String
    /// Declared variables whose value was supplied but empty, in first-seen order.
    public var missing: [String]
    /// Variables no value was supplied for at all, in first-seen order. Their `{{token}}` survives
    /// into `text` untouched.
    public var unknown: [String]

    public init(text: String, missing: [String] = [], unknown: [String] = []) {
        self.text = text
        self.missing = missing
        self.unknown = unknown
    }
}

/// The substitution rules shared by every configurable prompt.
///
/// `{{name}}` and nothing else. Braces were chosen over `$NAME` because a prompt is prose that
/// routinely contains shell commands, and `$` in that prose would have to be escaped constantly.
/// Anything between the braces that is not a plain identifier is left exactly as written, so a
/// template may still talk about JSON, Handlebars or Blade without its own examples being eaten.
public enum PromptTemplate {
    public static let open = "{{"
    public static let close = "}}"

    /// The wrapped form of a variable name, which is what the settings UI shows the user.
    public static func token(_ name: String) -> String {
        "\(open)\(name)\(close)"
    }

    public static func render(_ template: String, values: [String: String]) -> PromptRender {
        var text = ""
        var missing: [String] = []
        var unknown: [String] = []
        var cursor = template.startIndex

        while let opening = template.range(of: open, range: cursor..<template.endIndex) {
            guard let closing = template.range(of: close, range: opening.upperBound..<template.endIndex)
            else { break }

            let raw = String(template[opening.upperBound..<closing.lowerBound])
            let name = raw.trimmingCharacters(in: .whitespaces)

            guard isVariableName(name) else {
                // Not a variable at all. Copied through with its braces, including the delimiters
                // themselves, so a template that documents this very syntax survives a render.
                text += template[cursor..<closing.upperBound]
                cursor = closing.upperBound
                continue
            }

            text += template[cursor..<opening.lowerBound]

            if let value = values[name] {
                if value.isEmpty { append(name, to: &missing) }
                text += value
            } else {
                append(name, to: &unknown)
                text += template[opening.lowerBound..<closing.upperBound]
            }

            cursor = closing.upperBound
        }

        text += template[cursor...]
        return PromptRender(text: text, missing: missing, unknown: unknown)
    }

    /// Every variable a template refers to, in first-seen order. Used to check a template against
    /// the definition it belongs to without rendering it.
    public static func variableNames(in template: String) -> [String] {
        let render = render(template, values: [:])
        return render.unknown
    }

    /// Identifiers only: letters, digits and underscore. Deliberately narrow, because the whole
    /// point of the check is to tell a variable apart from prose that happens to sit in braces.
    static func isVariableName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func append(_ name: String, to list: inout [String]) {
        guard !list.contains(name) else { return }
        list.append(name)
    }
}
