import Foundation
import Testing
@testable import BloomCore

@Suite("Whether a capture is photographing this tree")
struct CaptureFreshnessTests {
    private let built = Date(timeIntervalSince1970: 1_000)

    /// The morning this type is named after. The binary was linked before the commit landed, the
    /// capture showed the footer without the button, and the picture was read as the bug.
    @Test("a source changed after the link is stale")
    func sourceNewerThanBinaryIsStale() {
        #expect(
            CaptureFreshness.of(builtAt: built, newestSourceChangeAt: built.addingTimeInterval(1))
                == .stale
        )
    }

    @Test("a binary linked after the last change is current")
    func binaryNewerThanSourceIsCurrent() {
        #expect(
            CaptureFreshness.of(builtAt: built, newestSourceChangeAt: built.addingTimeInterval(-1))
                == .current
        )
    }

    /// A build reads the sources and then writes the executable, so the same second means a file
    /// that was touched rather than changed. Refusing it would refuse a build that is up to date.
    @Test("the same instant is current, not stale")
    func equalIsCurrent() {
        #expect(CaptureFreshness.of(builtAt: built, newestSourceChangeAt: built) == .current)
    }

    /// Every shipped copy, and any build run from outside its checkout. Nothing to compare is
    /// nothing to say: a guess here would refuse captures that are perfectly good.
    @Test("with no source tree to compare against, nothing is claimed")
    func missingEitherSideIsUnknowable() {
        #expect(CaptureFreshness.of(builtAt: built, newestSourceChangeAt: nil) == .unknowable)
        #expect(CaptureFreshness.of(builtAt: nil, newestSourceChangeAt: built) == .unknowable)
        #expect(CaptureFreshness.of(builtAt: nil, newestSourceChangeAt: nil) == .unknowable)
    }

    @Test("only a stale verdict has anything to say, and it names the remedy")
    func onlyStaleRefuses() {
        #expect(CaptureFreshness.current.refusal(flag: "--snapshot-window") == nil)
        #expect(CaptureFreshness.unknowable.refusal(flag: "--snapshot-window") == nil)

        let refusal = CaptureFreshness.stale.refusal(flag: "--snapshot-window")
        #expect(refusal?.contains("--snapshot-window") == true)
        #expect(refusal?.contains("swift build") == true)
    }
}
