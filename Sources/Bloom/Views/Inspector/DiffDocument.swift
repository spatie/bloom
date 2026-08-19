import Foundation
import BloomCore

/// Everything a diff needs that is worth computing exactly once.
///
/// Lexer carry, word level highlight ranges and the widest line are all sequential or expensive,
/// and all three are needed by rows that a lazy stack will build in an unpredictable order and
/// rebuild many times. Computing them in one background pass turns the render into a lookup.
struct DiffDocument: Sendable {
    var file: FileDiff
    var language: Language
    /// Keyed by `DiffLine.index`: the lexer state each line begins in.
    var carries: [Int: LexState]
    /// Keyed by `DiffLine.index`: the spans that differ from the line this one is paired with.
    var emphasis: [Int: [Range<String.Index>]]
    var maxColumns: Int

    /// Past this many paired lines the word diff stops. A file with thousands of paired edits is
    /// being skimmed, not read, and the LCS per pair is the one superlinear cost in the pass.
    private static let emphasisLimit = 4_000

    /// A horizontal scroll wider than this helps nobody and makes the scroller useless.
    private static let columnLimit = 800

    static func parse(patch: String, path: String) -> FileDiff? {
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
    static func prepare(file: FileDiff, path: String) -> DiffDocument {
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
                maxColumns = max(maxColumns, CodeMetrics.columns(of: line.text))

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
}
