import Foundation

/// Why one of the four quick prompt tools would not act, in terms a model can act on.
///
/// Built to the standard `ProjectHideTrouble` and `WorkspaceStartTrouble` set, and for the same
/// reason: a model told "invalid input" tries the same call again. Every sentence here names the
/// argument that was wrong, says whether retrying unchanged can help, and says what would have
/// worked instead.
///
/// The refusals are a type of their own rather than string literals at each site because three of
/// the four tools share most of them, and a pair of sentences that describe the same failure
/// differently is how a model learns that two tools disagree about what a quick prompt is.
///
/// An `Error` as well as a value, so the readings below can be a `Result` the way `PaneRefusal`
/// is. Nothing throws it: every site switches on the two cases and answers with the sentence.
public enum QuickPromptTrouble: Error, Sendable, Equatable {
    /// `quick_prompt_create` arrived with no text, or with nothing but whitespace in it.
    case noText
    /// `quick_prompt_update` was passed `text` and it was blank. Distinct from `noText`, because
    /// here leaving the argument out is the thing the caller wanted and is worth saying.
    case blankText(field: String)
    /// No prompt was named. Both tools that change a row need one.
    case noID(tool: String)
    /// An id that matches nothing. Carries the library, so the next call can be right rather than
    /// another guess.
    case unknownID(id: String, known: [QuickPrompt])
    /// There are no quick prompts at all, so there is nothing to change or remove.
    case emptyLibrary(tool: String)
    /// `quick_prompt_update` named a prompt and then nothing to do to it.
    case nothingToChange
    /// A mark neither view could draw. See `QuickPromptMark`.
    case unknownSymbol(String)
    /// Anything the store threw, said plainly.
    case unexplained(tool: String, message: String)

    public var sentence: String {
        switch self {
        case .noText:
            return """
                quick_prompt_create needs the 'text' the prompt puts in the composer, and it \
                cannot be blank: a prompt with no words in it inserts nothing. 'name' and \
                'symbol' are optional, 'text' is the prompt.
                """

        case .blankText(let field):
            return """
                '\(field)' arrived empty, and a quick prompt with no words in it inserts nothing. \
                Pass the text the prompt should put in the composer, or leave '\(field)' out \
                entirely to keep the text this prompt already has.
                """

        case .noID(let tool):
            return """
                \(tool) needs the 'id' of the quick prompt to act on, which is the id \
                quick_prompt_list prints. It takes an id and not a name, because two prompts can \
                share a name and picking one of them would be the wrong prompt. Call \
                quick_prompt_list first.
                """

        case let .unknownID(id, known):
            return """
                Bloom has no quick prompt with the id '\(id)'. It has \(Self.listing(known)). \
                Retrying with the same id will fail the same way: call quick_prompt_list and use \
                an id from its answer.
                """

        case .emptyLibrary(let tool):
            return """
                Bloom has no quick prompts, so \(tool) has nothing to act on. Retrying will not \
                change that. quick_prompt_create is what writes one.
                """

        case .nothingToChange:
            return """
                quick_prompt_update was given a prompt and nothing to do to it. Pass at least one \
                of 'name', 'symbol' or 'text'. Whatever you leave out keeps the value it already \
                has, so changing the name alone is a call with 'id' and 'name' and nothing else.
                """

        case .unknownSymbol(let symbol):
            return """
                Bloom cannot draw '\(symbol)' as a quick prompt's mark, and a mark it cannot draw \
                is a blank down the left of the row. Pass one emoji, or one of the SF Symbol \
                names Bloom's own picker offers, such as \(Self.symbolExamples). Leave 'symbol' \
                out for Bloom's default.
                """

        case let .unexplained(tool, message):
            return "Bloom could not finish \(tool): \(message)"
        }
    }

    /// Three symbol names to steer a model that guessed at one.
    ///
    /// Read off the picker's own catalogue rather than written out, so a band renamed there cannot
    /// leave this refusal recommending a name `QuickPromptMark` would then refuse. Three, because
    /// the point is to show the shape of a name rather than to publish a hundred of them; a model
    /// that wants a particular mark has an emoji, which always works.
    static var symbolExamples: String {
        let names = ["doc.richtext", "hammer", "text.alignleft"].filter(QuickPrompt.knownSymbols.contains)
        let usable = names.isEmpty ? Array(QuickPrompt.symbols.prefix(3)) : names
        return usable.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// How many prompts a refusal names before it stops and points at the list.
    ///
    /// The refusal goes straight into the model's context, and a library of eighty prompts quoted
    /// in full would be eighty rows of the owner's writing spent on saying "not that id".
    static let listingLimit = 12

    static func listing(_ prompts: [QuickPrompt]) -> String {
        guard !prompts.isEmpty else { return "none at all" }
        let named = prompts.prefix(listingLimit)
            .map { "'\($0.resolvedName)' (id \($0.id.rawValue))" }
            .joined(separator: ", ")
        guard prompts.count > listingLimit else { return named }
        return "\(named), and \(prompts.count - listingLimit) more"
    }
}
