import Foundation

public extension Error {
    /// The sentence to put in front of a person.
    ///
    /// `"\(error)"` is the wrong thing to show almost everywhere. On a Swift enum it prints the
    /// case name and its associated values (`noSuchFile("/Users/…")`), on a bridged `NSError` it
    /// prints the whole domain, code and user info dictionary, and on a `DecodingError` it prints
    /// several lines of coding keys. None of those are a sentence, and all of them have been shown
    /// to users in an alert at some point.
    ///
    /// Baton's own error types all write their own message, so those are asked first. Everything
    /// from Foundation and AppKit is asked for its localised description instead, which is the one
    /// string those frameworks write for people rather than for a log.
    var readableMessage: String {
        // Value types only. Every Swift error answers `is NSError` because it bridges on demand,
        // so that is no way to tell one of ours from one of Foundation's: the metatype is.
        if let described = self as? CustomStringConvertible, !(type(of: self) is AnyClass) {
            return Self.asSentence(described.description)
        }
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return Self.asSentence(description)
        }

        let cocoa = self as NSError
        // Foundation's fallback for an error nobody localised: it names the module and a number
        // and says nothing else.
        let isPlaceholder = cocoa.localizedDescription.contains("(\(cocoa.domain) error \(cocoa.code)")
        if !isPlaceholder, !cocoa.localizedDescription.isEmpty {
            return Self.asSentence(cocoa.localizedDescription)
        }

        // Nobody wrote a message for this one, so the value itself is the most specific thing
        // there is. It is deliberately not shaped: it is an identifier rather than prose, and
        // capitalising `cannotReachTheServer` only makes it look like a mistake.
        return String(describing: self)
    }

    /// Error messages are written to be embedded (`"could not archive: \(error)"`), so they arrive
    /// lowercase and without a stop. On their own in an alert that reads as a fragment, and a
    /// fragment is not something you say to a person: "not a directory" is a compiler talking.
    private static func asSentence(_ message: String) -> String {
        var trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Something went wrong." }

        // Only a plain lowercase letter is raised. A path, a `command`, a quoted string or an
        // identifier is a name, and renaming it would be worse than starting mid-case.
        if first.isLowercase, first.isLetter {
            trimmed.replaceSubrange(trimmed.startIndex...trimmed.startIndex, with: first.uppercased())
        }
        if let last = trimmed.last, !".!?:".contains(last) {
            trimmed.append(".")
        }
        return trimmed
    }
}
