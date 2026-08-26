import Testing
@testable import BloomCore

/// The set exists so the three can be compared in one place, and the two things that make that
/// worth anything are that the gallery draws all of them and that the window draws one of them.
/// Both are properties a test can hold and neither is obvious from reading a switch.
@Suite("Which figure the activity rule draws")
struct BusyRuleVariantTests {
    /// The gallery walks `allCases` and the window draws `live`. A variant added without being
    /// drawn anywhere is a variant nobody will ever look at, which is the failure this whole set
    /// was built to avoid.
    @Test("the one the window draws is one of the ones the gallery draws")
    func liveIsInTheSet() {
        #expect(BusyRuleVariant.allCases.contains(BusyRuleVariant.live))
        #expect(BusyRuleVariant.allCases.count == 3)
    }

    /// Every case has to say what it is, because the page is a comparison and a comparison with an
    /// unlabelled column in it is a picture somebody has to be told about out loud.
    @Test("every variant names itself and says what it does")
    func everyVariantIsDescribed() {
        for variant in BusyRuleVariant.allCases {
            #expect(!variant.title.isEmpty)
            #expect(!variant.note.isEmpty)
        }
        #expect(Set(BusyRuleVariant.allCases.map(\.title)).count == BusyRuleVariant.allCases.count)
    }

    /// The property the mark switches on: a travelling figure is a layer being moved along the
    /// rule, and a still one is the rule itself changing. The incumbent is the one that does not
    /// travel, and the one the window took does.
    @Test("the swell is the only one that stays where it is")
    func onlyTheSwellStaysPut() {
        #expect(BusyRuleVariant.swell.travels == false)
        #expect(BusyRuleVariant.crest.travels)
        #expect(BusyRuleVariant.current.travels)
        #expect(BusyRuleVariant.live.travels, "the report was that a still line says nothing")
    }
}
