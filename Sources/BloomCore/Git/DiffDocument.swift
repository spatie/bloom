import Foundation

/// Everything a diff needs that is worth computing exactly once.
///
/// Lexer carry, word level highlight ranges and the widest line are all sequential or expensive,
/// and all three are needed by rows that a lazy stack will build in an unpredictable order and
/// rebuild many times. Computing them in one background pass turns the render into a lookup.
public struct DiffDocument: Sendable {
    public var file: FileDiff
    public var language: Language
    /// Keyed by `DiffLine.index`: the lexer state each line begins in.
    public var carries: [Int: LexState]
    /// Keyed by `DiffLine.index`: the spans that differ from the line this one is paired with.
    public var emphasis: [Int: [Range<String.Index>]]
    public var maxColumns: Int

    /// Past this many paired lines the word diff stops. A file with thousands of paired edits is
    /// being skimmed, not read, and the LCS per pair is the one superlinear cost in the pass.
    private static let emphasisLimit = 4_000

    /// A horizontal scroll wider than this helps nobody and makes the scroller useless.
    private static let columnLimit = 800

    public static func parse(patch: String, path: String) -> FileDiff? {
        let files = DiffParser.parse(patch)
        return files.first { $0.displayPath == path } ?? files.first
    }

    /// The one sequential pass. Old and new lines are lexed with separate carry states because
    /// they are two different versions of the file: a block comment opened by a deletion must not
    /// leak into the additions rendered next to it.
    ///
    /// Context skipped between hunks is a known gap in this reasoning. Git only gives us the lines
    /// it printed, so a construct opened inside the skipped region cannot be seen, and the first
    /// lines of the next hunk may highlight as if it were never opened.
    public static func prepare(file: FileDiff, path: String) -> DiffDocument {
        let language = Language.detect(path: path)
        // Plain text has no construct that can span a line, so the whole sequential pass would
        // only ever hand back a clean state. Skipping it makes an unrecognised file free.
        let needsCarry = language != .plainText
        var carries: [Int: LexState] = [:]
        var emphasis: [Int: [Range<String.Index>]] = [:]
        var oldState = LexState()
        var newState = LexState()
        var maxColumns = 0
        var pairsComputed = 0

        for hunk in file.hunks {
            var deletions: [DiffLine] = []
            var additions: [DiffLine] = []

            func flushPairs() {
                let count = min(deletions.count, additions.count)
                for offset in 0..<count {
                    guard pairsComputed < emphasisLimit else { break }
                    pairsComputed += 1
                    let before = deletions[offset]
                    let after = additions[offset]
                    let (left, right) = DiffParser.intraLineDiff(before.text, after.text)
                    if !left.isEmpty { emphasis[before.index] = left }
                    if !right.isEmpty { emphasis[after.index] = right }
                }
                deletions.removeAll(keepingCapacity: true)
                additions.removeAll(keepingCapacity: true)
            }

            for line in hunk.lines {
                maxColumns = max(maxColumns, CodeColumns.count(of: line.text))

                switch line.kind {
                case .context:
                    flushPairs()
                    guard needsCarry else { continue }
                    carries[line.index] = newState
                    var oldCopy = oldState
                    _ = SyntaxHighlighter.tokenize(line: line.text, language: language, carry: &oldCopy)
                    oldState = oldCopy
                    _ = SyntaxHighlighter.tokenize(line: line.text, language: language, carry: &newState)
                case .deletion:
                    deletions.append(line)
                    guard needsCarry else { continue }
                    carries[line.index] = oldState
                    _ = SyntaxHighlighter.tokenize(line: line.text, language: language, carry: &oldState)
                case .addition:
                    additions.append(line)
                    guard needsCarry else { continue }
                    carries[line.index] = newState
                    _ = SyntaxHighlighter.tokenize(line: line.text, language: language, carry: &newState)
                case .noNewline:
                    break
                }
            }
            flushPairs()
        }

        return DiffDocument(
            file: file,
            language: language,
            carries: carries,
            emphasis: emphasis,
            maxColumns: min(maxColumns, columnLimit)
        )
    }

    /// The printed lines a renderer should highlight before anybody asks for them, each with the
    /// lexer state it begins in.
    ///
    /// Every line of a diff was lexed twice. `prepare` above walks the whole file to thread the
    /// carry state and throws the tokens away, and then the first time a row was built the view's
    /// own highlight cache lexed the same line again, on the main thread, while the reader was
    /// waiting to see it. Handing this list to that cache from a background task turns the first
    /// draw of every row it covers into a lookup.
    ///
    /// Bounded, and deliberately from the top: a reader arrives at the first hunk, and the cache
    /// this feeds holds a few thousand lines in total across every open file, so priming a whole
    /// large diff would only evict what it had just put in.
    public func linesToPrime(limit: Int) -> [(text: String, carry: LexState)] {
        guard limit > 0 else { return [] }
        var result: [(text: String, carry: LexState)] = []
        result.reserveCapacity(limit)
        for hunk in file.hunks {
            for line in hunk.lines where line.kind != .noNewline {
                result.append((line.text, carries[line.index] ?? LexState()))
                if result.count == limit { return result }
            }
        }
        return result
    }
}
