import SwiftUI
import AppKit
import BatonCore

private final class SyntaxKey: NSObject {
    let line: String
    let language: Language
    let carry: LexState
    private let cachedHash: Int

    init(line: String, language: Language, carry: LexState) {
        self.line = line
        self.language = language
        self.carry = carry
        var hasher = Hasher()
        hasher.combine(line)
        hasher.combine(language)
        hasher.combine(carry)
        self.cachedHash = hasher.finalize()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SyntaxKey else { return false }
        return cachedHash == other.cachedHash
            && line == other.line
            && language == other.language
            && carry == other.carry
    }
}

private final class SyntaxBox {
    let value: AttributedString

    init(_ value: AttributedString) { self.value = value }
}

/// Memoised highlighting, shared by every code view in the app.
///
/// `NSCache` rather than a dictionary: it does its own locking, so a background preparation pass
/// and the main thread can both prime it, and it evicts under memory pressure instead of growing
/// with the size of the largest file the user happened to open.
enum SyntaxCache {
    /// Roughly a few screens of several open files. Past this, re-lexing a line costs less than
    /// the memory of remembering it.
    private static let limit = 4_000

    // NSCache is documented as thread safe, which is the whole reason it is used here.
    nonisolated(unsafe) private static let storage: NSCache<SyntaxKey, SyntaxBox> = {
        let cache = NSCache<SyntaxKey, SyntaxBox>()
        cache.countLimit = limit
        return cache
    }()

    static func attributed(line: String, language: Language, carry: LexState) -> AttributedString {
        let key = SyntaxKey(line: line, language: language, carry: carry)
        if let hit = storage.object(forKey: key) { return hit.value }

        let value = build(line: line, language: language, carry: carry)
        storage.setObject(SyntaxBox(value), forKey: key)
        return value
    }

    private static func build(line: String, language: Language, carry: LexState) -> AttributedString {
        var value = AttributedString(line)
        value.foregroundColor = Palette.textPrimary
        guard !line.isEmpty else { return value }

        var state = carry
        let tokens = SyntaxHighlighter.tokenize(line: line, language: language, carry: &state)

        for token in tokens where token.kind != .plain {
            guard let range = CodeText.attributedRange(
                forUTF16: token.range, of: line, in: value
            ) else { continue }
            value[range].foregroundColor = CodeText.color(for: token.kind)
        }
        return value
    }
}
