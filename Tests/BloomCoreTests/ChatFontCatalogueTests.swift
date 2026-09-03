import Testing
import Foundation
@testable import BloomCore

@Suite("The faces the conversation can be set in")
struct ChatFontCatalogueTests {
    /// A stand-in for what the font manager answers: the two families the recommendations name,
    /// a few real text faces, and the symbol and hidden faces a picker must not offer.
    private static let installed = [
        "Charter",
        "Verdana",
        "Helvetica Neue",
        "Avenir Next",
        "Georgia",
        "Palatino",
        "Apple Color Emoji",
        "Apple Symbols",
        "Bodoni Ornaments",
        "Zapf Dingbats",
        "Webdings",
        "Apple Braille",
        "Symbol",
        ".AppleSystemUIFont",
    ]

    private static let installedSet = Set(installed)

    // MARK: The four that were there before there was a list

    /// The whole of "do not strand a setting somebody has already chosen". Each of the four values
    /// the segmented control could write still resolves to the face it drew.
    @Test("every value the four-way control wrote still resolves to the same face")
    func theOldValuesStillWork() {
        #expect(ChatFontCatalogue.resolve("system", installed: Self.installedSet) == .system)
        #expect(ChatFontCatalogue.resolve("reading", installed: Self.installedSet) == .serif)
        #expect(ChatFontCatalogue.resolve("book", installed: Self.installedSet) == .family("Charter"))
        #expect(ChatFontCatalogue.resolve("legible", installed: Self.installedSet) == .family("Verdana"))
    }

    /// The two that moved arrive as the family they were always a label over, so the old spelling
    /// and the new one are one setting rather than two.
    @Test("the two old labels canonicalise to the family they named")
    func theOldLabelsBecomeFamilies() {
        #expect(ChatFontCatalogue.canonicalID("book") == "Charter")
        #expect(ChatFontCatalogue.canonicalID("legible") == "Verdana")
        #expect(ChatFontCatalogue.canonicalID("system") == "system")
        #expect(ChatFontCatalogue.canonicalID("reading") == "reading")
    }

    @Test("an old value keeps the name and the sentence the picker showed for it")
    func theOldValuesKeepTheirCopy() {
        #expect(ChatFontCatalogue.recommendation(for: "book")?.title == "Book")
        #expect(ChatFontCatalogue.recommendation(for: "legible")?.title == "Legible")
        #expect(
            ChatFontCatalogue.summary(for: "book", installed: Self.installedSet)
                == ChatFontCatalogue.summary(for: "Charter", installed: Self.installedSet)
        )
        #expect(
            ChatFontCatalogue.summary(for: "system", installed: Self.installedSet)
                .hasPrefix("San Francisco, the face the rest of macOS is set in.")
        )
    }

    @Test("the four head the list, in the order they were offered in")
    func theFourStillHeadTheList() {
        #expect(ChatFontCatalogue.curated.map(\.title) == ["System", "Reading", "Book", "Legible"])
        #expect(ChatFontCatalogue.curated.first?.id == ChatFontCatalogue.standardID)
        #expect(ChatFontCatalogue.curated.allSatisfy { !$0.summary.isEmpty })
    }

    // MARK: An open set

    @Test("a family that is installed resolves to itself")
    func anInstalledFamilyResolves() {
        #expect(ChatFontCatalogue.resolve("Palatino", installed: Self.installedSet) == .family("Palatino"))
        #expect(ChatFontCatalogue.recommendation(for: "Palatino") == nil)
        #expect(
            ChatFontCatalogue.summary(for: "Palatino", installed: Self.installedSet)
                == "Palatino, one of the fonts installed on this Mac."
        )
    }

    /// The reason the resolution is a function of two arguments rather than a property of the
    /// stored value. A font disabled in Font Book, or a defaults domain carried over from another
    /// Mac, leaves a name here that nothing can draw.
    @Test("a family that is not installed falls back to the system face, and says so")
    func aMissingFamilyFallsBack() {
        #expect(ChatFontCatalogue.resolve("Comic Sans MS", installed: Self.installedSet) == .system)
        #expect(
            ChatFontCatalogue.summary(for: "Comic Sans MS", installed: Self.installedSet)
                .hasPrefix("Comic Sans MS is not installed on this Mac.")
        )
    }

    /// The same answer for a recommendation, because two of the four are families too and a Mac
    /// with Charter disabled is a Mac where Book cannot be drawn.
    @Test("a recommendation whose family is gone falls back the same way")
    func aMissingRecommendationFallsBack() {
        let withoutCharter = Self.installedSet.subtracting(["Charter"])
        #expect(ChatFontCatalogue.resolve("book", installed: withoutCharter) == .system)
        #expect(
            ChatFontCatalogue.summary(for: "book", installed: withoutCharter)
                .hasPrefix("Charter is not installed on this Mac.")
        )
        // The two that are not families cannot go missing, whatever is installed.
        #expect(ChatFontCatalogue.resolve("system", installed: []) == .system)
        #expect(ChatFontCatalogue.resolve("reading", installed: []) == .serif)
    }

    @Test("nothing stored, and nothing but spaces stored, are the standard")
    func anEmptySettingIsTheStandard() {
        #expect(ChatFontCatalogue.canonicalID(nil) == ChatFontCatalogue.standardID)
        #expect(ChatFontCatalogue.canonicalID("") == ChatFontCatalogue.standardID)
        #expect(ChatFontCatalogue.canonicalID("   ") == ChatFontCatalogue.standardID)
        #expect(ChatFontCatalogue.resolve(nil, installed: Self.installedSet) == .system)
        #expect(ChatFontCatalogue.resolve("", installed: Self.installedSet) == .system)
        #expect(ChatFontCatalogue.resolve("  Charter  ", installed: Self.installedSet) == .family("Charter"))
    }

    // MARK: What the list under the four holds

    @Test("the list is sorted, and drops the faces no paragraph is legible in")
    func theListIsWhatCanBeReadIn() {
        let families = ChatFontCatalogue.families(from: Self.installed)
        #expect(families == ["Avenir Next", "Georgia", "Helvetica Neue", "Palatino"])
    }

    /// Not a repeat of the four: their ids are the family names, so Charter twice would be two
    /// rows carrying one tag.
    @Test("the recommendations are not repeated under themselves")
    func theRecommendationsAppearOnce() {
        let families = ChatFontCatalogue.families(from: Self.installed)
        #expect(!families.contains("Charter"))
        #expect(!families.contains("Verdana"))
    }

    @Test("a duplicate name in the font manager's list is one row")
    func duplicatesCollapse() {
        let families = ChatFontCatalogue.families(from: ["Georgia", "Georgia", " Georgia "])
        #expect(families == ["Georgia"])
    }

    /// `ComposerOption.adding` for a font: the value the app is in stays on the control that could
    /// put it back, so choosing another face is not a one-way door.
    @Test("a selected family that is no longer installed keeps its row")
    func theSelectionSurvivesItsFontGoingMissing() {
        let families = ChatFontCatalogue.families(from: Self.installed, keeping: "Comic Sans MS")
        #expect(families.last == "Comic Sans MS")
        #expect(families.count == 5)
    }

    @Test("a selected recommendation adds nothing to the list under it")
    func aRecommendedSelectionAddsNoRow() {
        let plain = ChatFontCatalogue.families(from: Self.installed)
        #expect(ChatFontCatalogue.families(from: Self.installed, keeping: "book") == plain)
        #expect(ChatFontCatalogue.families(from: Self.installed, keeping: "system") == plain)
        #expect(ChatFontCatalogue.families(from: Self.installed, keeping: "Georgia") == plain)
        #expect(ChatFontCatalogue.families(from: Self.installed, keeping: nil) == plain)
    }

    // MARK: Inline code against the prose it sits in

    /// The x-heights the four faces measure at 13 points on macOS 26, and the two constants the
    /// enum used to carry. The ratio is what those constants were derived from, so it has to
    /// reproduce them exactly or a face that has not changed would be set differently.
    @Test("the measured x-heights reproduce the constants the four faces carried")
    func theRatioReproducesTheMeasuredConstants() {
        let mono = 6.87451171875
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 6.8427734375, monoXHeight: mono) == 1)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 6.296875, monoXHeight: mono) == 0.92)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 6.31591796875, monoXHeight: mono) == 0.92)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 7.09033203125, monoXHeight: mono) == 1)
    }

    @Test("code is never set larger than the prose around it, or too small to read")
    func theRatioIsHeldAtBothEnds() {
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 12, monoXHeight: 6.87) == 1)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 2, monoXHeight: 6.87) == 0.8)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 0, monoXHeight: 6.87) == 1)
        #expect(ChatFontCatalogue.inlineCodeScale(faceXHeight: 6.87, monoXHeight: 0) == 1)
    }
}
