import Foundation

/// What the quick prompt panel draws, in the order the arrow keys walk it.
///
/// Pure and `nonisolated`, in the shape of `WorkspaceSourceMatches` and for the same reason: the
/// panel asks this on every keystroke, and a ranking that sat on an actor would be a hop per
/// character. The keyboard behaviour is here too, because a decision taken inside a view is a
/// decision nothing can test.
public struct QuickPromptMatches: Sendable, Hashable {
    /// What was searched for, so the empty state can say it rather than shrugging, and so the
    /// "New quick prompt" row can offer to call the new prompt by it. Somebody who searched for a
    /// prompt they have not written yet has just said what it should be called.
    public let query: String
    public let prompts: [QuickPrompt]

    public init(query: String = "", prompts: [QuickPrompt] = []) {
        self.query = query
        self.prompts = prompts
    }

    public var isEmpty: Bool { prompts.isEmpty }

    /// Ranks the whole list against what is in the search field.
    ///
    /// **The name is matched as a subsequence and the text is matched as a substring, and the two
    /// halves are deliberately different.** `FuzzyMatch` answers "every character of the query
    /// appears in order", which is exactly right for a short name and useless against a paragraph:
    /// a hundred word prompt contains almost every short query as a subsequence, so scoring the
    /// body that way would keep every row for every query and the panel would never say "nothing
    /// matches". Containment is what a person means when they say the word is in there, and it is
    /// what makes "test" keep a prompt whose title never mentions tests.
    ///
    /// An empty query is the list itself, in its stored order.
    public static func ranking(
        _ prompts: [QuickPrompt], query: String, limit: Int = 100
    ) -> QuickPromptMatches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QuickPromptMatches(query: trimmed, prompts: Array(prompts.prefix(limit)))
        }

        var scored: [(prompt: QuickPrompt, score: Int, position: Int)] = []
        scored.reserveCapacity(prompts.count)
        for (position, prompt) in prompts.enumerated() {
            let name = FuzzyMatch.score(prompt.resolvedName, query: trimmed)
            let body = prompt.text.range(of: trimmed, options: .caseInsensitive) != nil
                // Below any hit in the name, whatever the name scored: the row the query names is
                // the one that was meant, and the body is how a badly named one is recovered.
                ? bodyScore
                : nil
            guard name != nil || body != nil else { continue }
            scored.append((prompt, (name ?? 0) + (body ?? 0), position))
        }
        // Ties keep the order they arrived in, so a list that is not being searched reads as a
        // list rather than as a shuffle.
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.position < rhs.position
        }
        return QuickPromptMatches(query: trimmed, prompts: scored.prefix(limit).map(\.prompt))
    }

    /// What a hit in the body is worth. Small, so that any hit in the name outranks it: the
    /// cheapest name match `FuzzyMatch` can report is a single late character, which still scores
    /// above this once the length bonus is counted.
    private static let bodyScore = 1

    /// Where the highlight lands after a step, given what is highlighted now.
    ///
    /// The wrapping and the empty-highlight rule are `MenuRows`, which is where the third copy of
    /// them went when the permission picker wanted a fourth.
    public func stepped(from current: QuickPrompt?, by step: Int) -> QuickPrompt? {
        MenuRows.stepped(from: current, by: step, in: prompts)
    }

    /// What stays highlighted when the list changes under the field: the same row if it survived
    /// the new query, otherwise the best one there is now. A highlight left pointing at a row the
    /// query has filtered out is a Return that does nothing.
    ///
    /// By id rather than by value, because a row that has just been edited is the same row.
    public func settled(after current: QuickPrompt?) -> QuickPrompt? {
        guard let current, let held = prompts.first(where: { $0.id == current.id }) else {
            return prompts.first
        }
        return held
    }
}
