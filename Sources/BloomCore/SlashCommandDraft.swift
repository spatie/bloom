import Foundation

/// A draft, split into the `/command` it leads with and everything the user wrote after it.
///
/// The composer draws the command as a chip rather than as text, and this is the whole of that
/// translation. It is a pure function of the draft in both directions: nothing remembers that a
/// chip is up, so nothing can disagree with the text about whether one should be. `text` is the
/// literal string the CLI is handed, and `parse(text).text == text` for every draft, which is what
/// keeps a namespaced name like `superpowers:requesting-code-review` intact through a round trip.
///
/// A command is only recognised when the name is terminated by a single space, which is exactly
/// what picking one from the menu writes. That is what keeps `/Users/freek/notes.md` and
/// `/usr/bin/env` out of it: their first token ends at a slash, not at a space.
public struct SlashCommandDraft: Equatable, Sendable {
    /// The command's name without the leading slash, or nil when the draft does not lead with one.
    public var name: String?
    /// Everything after the space that terminates the name. The whole draft when there is no name.
    public var body: String

    public init(name: String?, body: String) {
        self.name = name
        self.body = body
    }

    /// The literal text, which is what gets sent.
    public var text: String {
        guard let name else { return body }
        return "/\(name) \(body)"
    }

    public static func parse(_ draft: String) -> SlashCommandDraft {
        let whole = SlashCommandDraft(name: nil, body: draft)
        guard draft.hasPrefix("/") else { return whole }

        let afterSlash = draft.dropFirst()
        let name = afterSlash.prefix(while: isNameCharacter)
        guard !name.isEmpty else { return whole }

        let rest = afterSlash.dropFirst(name.count)
        guard rest.first == " " else { return whole }

        return SlashCommandDraft(name: String(name), body: String(rest.dropFirst()))
    }

    /// The draft with the command gone and everything else untouched. What the chip's own close
    /// control does.
    public func removingCommand() -> SlashCommandDraft {
        SlashCommandDraft(name: nil, body: body)
    }

    /// What backspace at the very start of the draft should leave behind, or nil when there is no
    /// command for it to act on and AppKit should have the key.
    ///
    /// Two cases, and both read as "one press took one thing away". A chip with nothing after it
    /// becomes the text it was typed as, `/review`, with the caret at the end: the menu opens
    /// again and the next press eats a letter, which is what backspace on a word does. A chip with
    /// a written prompt after it is removed instead, because putting the name back would join it
    /// to the first word of the prompt and mangle both.
    public func backspacingCommand() -> SlashCommandDraft? {
        guard let name else { return nil }
        guard body.isEmpty else { return removingCommand() }
        return SlashCommandDraft(name: nil, body: "/\(name)")
    }

    /// Where the caret belongs after `backspacingCommand`, in UTF-16 units of the new body.
    public var caretAfterBackspace: Int {
        guard let name, body.isEmpty else { return 0 }
        return ("/\(name)" as NSString).length
    }

    /// The characters a command name may be spelled with.
    ///
    /// Deliberately the same set `SlashCommandIndex` accepts when it reads a name off disk: a name
    /// the index would offer has to be a name this recognises, or picking one from the menu would
    /// write a draft that never becomes a chip.
    public static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." || character == ":")
    }
}
