import Foundation

/// Cached highlighting must contain the exact source bytes. Swift string equality treats
/// composed and decomposed accents as equal, but their UTF-16 lengths differ. Reusing the
/// longer cached text for the shorter source made the wrapped diff apply attributes past its
/// end, raising an NSRangeException as the line scrolled into view.
public final class SyntaxCacheKey: NSObject {
    private let line: String
    private let language: Language
    private let carry: LexState
    private let cachedHash: Int

    public init(line: String, language: Language, carry: LexState) {
        self.line = line
        self.language = language
        self.carry = carry
        var hasher = Hasher()
        hasher.combine(line)
        hasher.combine(language)
        hasher.combine(carry)
        self.cachedHash = hasher.finalize()
    }

    public override var hash: Int { cachedHash }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SyntaxCacheKey else { return false }
        return cachedHash == other.cachedHash
            && line.utf8.elementsEqual(other.line.utf8)
            && language == other.language
            && carry == other.carry
    }
}
