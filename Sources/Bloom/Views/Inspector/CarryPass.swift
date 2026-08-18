import BloomCore

/// Lexer state per line, computed once for a whole file.
///
/// Block comments, heredocs and multiline strings only highlight correctly if the line above was
/// lexed first, which is exactly what a lazy list refuses to guarantee. Running the scanner once
/// up front, in order, and remembering the state each line *starts* in turns a sequential
/// dependency into a lookup that any row can do in any order.
enum CarryPass {
    /// The state each line begins in. Index `i` is the state before `lines[i]`.
    static func states(for lines: [String], language: Language) -> [LexState] {
        var state = LexState()
        var result: [LexState] = []
        result.reserveCapacity(lines.count)

        for line in lines {
            result.append(state)
            _ = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)
        }
        return result
    }
}
