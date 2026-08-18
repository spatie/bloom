import Foundation

/// Subsequence scoring shared by the file menu and the slash command menu.
///
/// Deliberately not a real fuzzy finder. The rule is only "every character of the query appears in
/// order", plus bonuses that push the obvious answer to the top: runs of adjacent characters,
/// matches at the start of a word, and a prefix match on the whole candidate.
enum FuzzyMatch {
    static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var total = 0
        var haystackIndex = 0
        var previousMatch = -2

        for character in needle {
            var matched = false
            while haystackIndex < haystack.count {
                let current = haystack[haystackIndex]
                haystackIndex += 1
                guard current == character else { continue }

                let position = haystackIndex - 1
                if position == previousMatch + 1 { total += 8 }
                if position == 0 { total += 12 }
                if position > 0, isBoundary(haystack[position - 1]) { total += 6 }
                total += 1
                previousMatch = position
                matched = true
                break
            }
            if !matched { return nil }
        }

        // Shorter candidates win ties, so `Store.swift` outranks `StoreMigrationsTests.swift`.
        return total + max(0, 40 - haystack.count)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == "/" || character == "_" || character == "-" || character == "." || character == " "
    }
}
