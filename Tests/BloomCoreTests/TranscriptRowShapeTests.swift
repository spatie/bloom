import Testing
@testable import BloomCore

/// Which cluster of row heights a stored row belongs to.
///
/// The mapping is the whole of this type, so it is what there is to test: a kind put in the wrong
/// cluster is a row estimated from rows it is nothing like, which is the fault the clusters exist
/// to end.
struct TranscriptRowShapeTests {
    /// **What somebody put in and what came back are two different questions**, and lumping them
    /// together is the first version of this that was measured and thrown away. A request is under
    /// a hundred points and much the same length every time; an answer is several hundred and
    /// varies by a factor of ten.
    @Test("a request and an answer are not the same shape")
    func splitsWhatIsWrittenFromWhatComesBack() {
        #expect(TranscriptRowShape.of(kind: .user) == .message)
        #expect(TranscriptRowShape.of(kind: .crew) == .message)
        #expect(TranscriptRowShape.of(kind: .assistantText) == .answer)
        #expect(TranscriptRowShape.of(kind: .thinking) == .answer)
    }

    /// A call, its result and the permission question drawn where the call would have been are one
    /// card and one size question.
    @Test("a call and its result are one shape")
    func groupsTheWorking() {
        #expect(TranscriptRowShape.of(kind: .toolUse) == .tool)
        #expect(TranscriptRowShape.of(kind: .toolResult) == .tool)
        #expect(TranscriptRowShape.of(kind: .permissionAsk) == .tool)
    }

    @Test("a turn's footer is its own shape, because it is the same rule every time")
    func footerIsItsOwn() {
        #expect(TranscriptRowShape.of(kind: .result) == .footer)
    }

    /// An error, a notice and the banner a session starts with are all a line or two in a box.
    @Test("what the app says about itself is one shape")
    func groupsTheNotices() {
        #expect(TranscriptRowShape.of(kind: .error) == .notice)
        #expect(TranscriptRowShape.of(kind: .notice) == .notice)
        #expect(TranscriptRowShape.of(kind: .system) == .notice)
    }

    /// **Nothing is classified as `.other`.** That case is for the four entries which are not
    /// stored rows at all, so a stored row falling into it would be a kind nobody grouped, drawn
    /// at the conversation's own mean for ever without anything saying so.
    @Test("every stored kind belongs somewhere")
    func nothingFallsThrough() {
        for kind in MessageKind.allCases {
            #expect(TranscriptRowShape.of(kind: kind) != .other)
        }
    }
}
