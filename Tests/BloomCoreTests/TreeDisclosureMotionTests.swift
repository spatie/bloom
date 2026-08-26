import Testing
@testable import BloomCore

/// A folder opening has two halves that are decided separately, and the whole reason this type
/// exists is that the cheap half must not be lost with the expensive one.
@Suite struct TreeDisclosureMotionTests {
    @Test func aFolderOfAFewFilesMakesRoomForThem() {
        #expect(TreeDisclosureMotion.rows(changing: 6, reduceMotion: false)
            == .animated(seconds: TranscriptMotion.disclosure(reduceMotion: false) ?? 0))
    }

    @Test func aFolderTooBigToWatchArrivesInstead() {
        // Past the limit every row that could travel has left the pane before the curve is a
        // third through, and what is left is a block fading in place.
        let limit = TreeDisclosureMotion.rowLimit
        #expect(TreeDisclosureMotion.rows(changing: limit, reduceMotion: false) != .instant)
        #expect(TreeDisclosureMotion.rows(changing: limit + 1, reduceMotion: false) == .instant)
    }

    @Test func anEmptyDirectoryHasNothingToTime() {
        #expect(TreeDisclosureMotion.rows(changing: 0, reduceMotion: false) == .instant)
        #expect(TreeDisclosureMotion.instant.seconds == nil)
    }

    @Test func theChevronTurnsWhateverTheFolderHolds() {
        // The one thing that is not thresholded: it is a rotation on a single glyph, so it costs
        // the same on a folder of two files and a folder of two thousand.
        #expect(TreeDisclosureMotion.chevron(reduceMotion: false).seconds != nil)
        #expect(TreeDisclosureMotion.rows(changing: 5_000, reduceMotion: false) == .instant)
    }

    @Test func reduceMotionDropsBothHalvesRatherThanSlowingThem() {
        #expect(TreeDisclosureMotion.rows(changing: 6, reduceMotion: true) == .instant)
        #expect(TreeDisclosureMotion.chevron(reduceMotion: true) == .instant)
    }

    @Test func itTakesTheSameLengthAsARowUnfoldingInTheTranscript() {
        // One gesture in two panes. Two lengths would read as two apps, which is the argument
        // `ProjectVisibilityMotion` is pinned to the same number by.
        #expect(TreeDisclosureMotion.chevron(reduceMotion: false).seconds
            == TranscriptMotion.disclosure(reduceMotion: false))
    }
}
