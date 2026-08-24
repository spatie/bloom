import Foundation

/// Subsequence scoring, shared by the file mention menu and the slash command menu.
///
/// Deliberately not a real fuzzy finder. The rule is only "every character of the query appears in
/// order", plus bonuses that push the obvious answer to the top: runs of adjacent characters,
/// matches at the start of a word, and a prefix match on the whole candidate.
///
/// There are two ways in, and the difference between them is cost. `score` runs a single greedy
/// left to right pass, which is what the file menu needs: it ranks every tracked path in the
/// repository on every keystroke, and a repository has tens of thousands of them. `hit` retries
/// from each later occurrence of the query's first character and keeps the best run, which finds
/// `review` inside `security-review` rather than settling for the stray `r` in `secu(r)ity`. That
/// costs more per candidate, so it is only used where the candidate list is a few hundred long.
public enum FuzzyMatch {
    public struct Hit: Sendable, Hashable {
        public var score: Int
        /// Character offsets into the candidate that the query matched, ascending.
        ///
        /// Empty when the offsets could not be trusted, which is the case for a candidate that
        /// changes length when it is lowercased. A caller that draws these has to survive an
        /// empty list anyway, so reporting nothing beats reporting an offset that is off by one.
        public var positions: [Int]

        public init(score: Int, positions: [Int]) {
            self.score = score
            self.positions = positions
        }
    }

    /// The cheap answer. One greedy pass, no retries.
    public static func score(_ candidate: String, query: String) -> Int? {
        best(candidate, query: query, startLimit: 1)?.score
    }

    /// The better answer, and the only one that can say which characters matched.
    ///
    /// `startLimit` bounds the retries, so a candidate full of the query's first letter cannot
    /// turn one keystroke into a quadratic scan.
    public static func hit(_ candidate: String, query: String, startLimit: Int = 24) -> Hit? {
        best(candidate, query: query, startLimit: startLimit)
    }

    // MARK: - Scoring

    private static func best(_ candidate: String, query: String, startLimit: Int) -> Hit? {
        guard !query.isEmpty else { return Hit(score: 0, positions: []) }

        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard needle.count <= haystack.count else { return nil }
        // See `Hit.positions`: a candidate whose lowercase form is a different length cannot have
        // its offsets mapped back onto the text the menu draws.
        let positionsAreTrustworthy = haystack.count == candidate.count

        var found: Hit?
        var tried = 0
        var start = 0

        while start < haystack.count, tried < startLimit {
            guard haystack[start] == needle[0] else {
                start += 1
                continue
            }
            tried += 1
            // A run that fails from here fails from every later start too: there is strictly less
            // of the candidate left to match against.
            guard let hit = greedy(haystack, needle, from: start) else { break }
            if found == nil || hit.score > found!.score { found = hit }
            start += 1
        }

        guard let found else { return nil }
        return positionsAreTrustworthy ? found : Hit(score: found.score, positions: [])
    }

    private static func greedy(_ haystack: [Character], _ needle: [Character], from start: Int) -> Hit? {
        var total = 0
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)

        var index = start
        var previousMatch = -2

        for character in needle {
            var matched = false
            while index < haystack.count {
                let current = haystack[index]
                index += 1
                guard current == character else { continue }

                let position = index - 1
                if position == previousMatch + 1 { total += 8 }
                if position == 0 { total += 12 }
                if position > 0, isBoundary(haystack[position - 1]) { total += 6 }
                total += 1
                previousMatch = position
                positions.append(position)
                matched = true
                break
            }
            if !matched { return nil }
        }

        // Shorter candidates win ties, so `Store.swift` outranks `StoreMigrationsTests.swift` and
        // `/review` outranks `/review-pr`.
        return Hit(score: total + max(0, 40 - haystack.count), positions: positions)
    }

    /// The colon is here because a plugin namespaces its commands with one, and `requesting` has
    /// to read as the start of a word in `superpowers:requesting-code-review`.
    private static func isBoundary(_ character: Character) -> Bool {
        character == "/" || character == "_" || character == "-"
            || character == "." || character == " " || character == ":"
    }
}
