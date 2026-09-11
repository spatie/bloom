import Foundation
import Testing
@testable import BloomCore

/// How much of a diff line is drawn, pinned for the line that froze the app in feedback #25: one
/// line of a minified bundle, several megabytes long, which the 5,000 line gate let through
/// because it counts lines.
struct DiffLineDisplayTests {
    @Test func anOrdinaryLineIsDrawnWhole() {
        let line = "    return $result->map(fn ($item) => ['invoice' => $item])->all();"
        #expect(DiffLineDisplay.text(line) == line)
    }

    @Test func aLineOfExactlyTheLimitIsDrawnWhole() {
        let line = String(repeating: "a", count: DiffLineDisplay.limit)
        #expect(DiffLineDisplay.text(line) == line)
    }

    @Test func aMinifiedLineIsCutAtTheLimitAndSaysHowMuchIsMissing() {
        let line = String(repeating: "var a=function(b){return b.x};", count: 120_000)
        let shown = DiffLineDisplay.text(line)

        #expect(shown.hasPrefix(String(line.prefix(DiffLineDisplay.limit))))
        #expect(shown.hasSuffix("more on this line, not shown"))
        #expect(shown.count < DiffLineDisplay.limit + 60)
    }

    /// Over the limit in bytes, within it in characters. Cutting by bytes would have split a line
    /// somebody can read.
    @Test func aLineOfWideCharactersWithinTheLimitIsDrawnWhole() {
        let line = String(repeating: "日本語", count: 600)
        #expect(line.utf8.count > DiffLineDisplay.limit)
        #expect(DiffLineDisplay.text(line) == line)
    }

    /// The cut is by character, so a flag or a skin toned emoji straddling it is kept or dropped
    /// whole rather than drawn as half of one.
    @Test func theCutNeverSplitsACharacter() {
        let line = String(repeating: "🇦🇹👍🏽", count: DiffLineDisplay.limit)
        let kept = DiffLineDisplay.text(line).prefix(DiffLineDisplay.limit)

        #expect(kept.allSatisfy { $0 == "🇦🇹" || $0 == "👍🏽" })
    }

    /// A shortened line has to be one the word diff already declined, or its emphasis ranges
    /// would point past the end of the text that is drawn.
    @Test func noShortenedLineCanCarryWordEmphasis() {
        #expect(DiffLineDisplay.limit >= DiffParser.intraLineLimit)
    }
}
