import Testing
import Foundation
@testable import BloomCore

@Suite("Preparing rows before a reader reaches them")
struct TranscriptWarmingTests {
    // MARK: How far

    /// A viewport or two, which is what a reader flicking back covers between one stop and the
    /// next.
    @Test("the reach is two screens")
    func reachIsTwoScreens() {
        #expect(TranscriptWarming.reach(viewport: 700) == 1_400)
        #expect(TranscriptWarming.reach(viewport: 300) == 600)
    }

    /// **A tall display is not a reason to prepare more of the conversation.** Two screens of a
    /// 1,600 point pane is a great deal of history and the reader is no likelier to travel it.
    @Test("the reach stops at the ceiling")
    func reachStopsAtTheCeiling() {
        #expect(TranscriptWarming.reach(viewport: 1_600) == TranscriptWarming.ceiling)
        #expect(TranscriptWarming.reach(viewport: 4_000) == TranscriptWarming.ceiling)
    }

    /// A pane that has not been laid out has no viewport, and preparing against it would reach
    /// into a band that means nothing.
    @Test("a pane with no height reaches nowhere")
    func noViewportNoReach() {
        #expect(TranscriptWarming.reach(viewport: 0) == 0)
        #expect(TranscriptWarming.reach(viewport: -10) == 0)
    }

    // MARK: How much

    /// **Points do not bound the work, which is the whole reason for a second number.** A band of
    /// points over the older history holds hundreds of rows that draw nothing, and preparing each
    /// of them still costs a hosting view.
    @Test("a band wider than the cap is cut to the rows nearest the reader")
    func aWideBandIsCut() {
        let band = 100..<900
        let warming = TranscriptWarming.worthWarming(band)
        #expect(warming.count == TranscriptWarming.mostRows)
        // Nearest the reader is the BOTTOM of a band above them, which is its upper bound.
        #expect(warming.upperBound == 900)
        #expect(warming.lowerBound == 900 - TranscriptWarming.mostRows)
    }

    @Test("a band inside the cap is taken whole")
    func aNarrowBandIsWhole() {
        let band = 10..<40
        #expect(TranscriptWarming.worthWarming(band) == band)
    }

    @Test("an empty band prepares nothing")
    func anEmptyBandIsNothing() {
        #expect(TranscriptWarming.worthWarming(7..<7).isEmpty)
    }

    /// A cap of nothing prepares nothing rather than everything, because a warm pass with no bound
    /// is a settle that measures a whole conversation.
    @Test("a cap of nothing prepares nothing")
    func noCapPreparesNothing() {
        #expect(TranscriptWarming.worthWarming(0..<500, most: 0).isEmpty)
    }
}
