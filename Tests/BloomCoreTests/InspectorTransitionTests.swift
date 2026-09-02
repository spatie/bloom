import Testing
@testable import BloomCore

/// The crash behind this is two `.ips` files with one stack: a SwiftUI `List` torn down inside
/// `removeFromSuperview` while its table was in live resize, aborting out of AttributeGraph. The
/// live resize is the inspector's animation, and the teardown is the detail column changing in the
/// same update. See `InspectorTransition`.
@Suite("The inspector's transition")
struct InspectorTransitionTests {
    @Test func slidesWhenOnlyTheInspectorIsChanging() {
        #expect(InspectorTransition.isAnimated(motionAllowed: true, contentIsChanging: false))
    }

    /// The pane is being swapped, so there is a `List` on its way out for the animation's live
    /// resize to race. This is the one that crashed.
    @Test func doesNotSlideWhileThePaneIsBeingSwapped() {
        #expect(!InspectorTransition.isAnimated(motionAllowed: true, contentIsChanging: true))
    }

    /// Reduce Motion is a complete answer on its own, whichever of the two is happening.
    @Test func reducedMotionWinsEitherWay() {
        #expect(!InspectorTransition.isAnimated(motionAllowed: false, contentIsChanging: false))
        #expect(!InspectorTransition.isAnimated(motionAllowed: false, contentIsChanging: true))
    }
}
