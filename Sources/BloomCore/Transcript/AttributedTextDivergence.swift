import Foundation

/// Where a new run of transcript text stops matching the one a text view already holds.
///
/// A streamed answer is rendered again from the top on every delta. Handing the whole result to
/// the text storage made TextKit throw its layout away and typeset the answer from the first line
/// each time, which was 61 per cent of the main thread while a 6,000 character answer arrived, and
/// grew with the answer. Replacing only what follows this offset keeps the layout above it.
public enum AttributedTextDivergence {
    /// The first UTF-16 offset at which the characters or the attributes differ, moved back to the
    /// start of a composed character so an edit never splits one. Equal to both lengths when the
    /// two are identical.
    public static func firstDifference(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        let sharedCharacters = old.string.commonPrefix(with: new.string, options: .literal).utf16.count
        let shared = sameAttributes(old, new, upTo: sharedCharacters)
        guard shared < new.length else { return shared }
        return (new.string as NSString).rangeOfComposedCharacterSequence(at: shared).location
    }

    private static func sameAttributes(_ old: NSAttributedString, _ new: NSAttributedString, upTo end: Int) -> Int {
        let span = NSRange(location: 0, length: end)
        var offset = 0
        while offset < end {
            var oldRun = NSRange()
            var newRun = NSRange()
            let oldAttributes = old.attributes(at: offset, longestEffectiveRange: &oldRun, in: span)
            let newAttributes = new.attributes(at: offset, longestEffectiveRange: &newRun, in: span)
            guard NSDictionary(dictionary: oldAttributes).isEqual(to: newAttributes) else { return offset }
            offset = min(NSMaxRange(oldRun), NSMaxRange(newRun))
        }
        return end
    }
}
