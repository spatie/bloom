import Testing
@testable import BloomCore

struct CodexTurnHandleTests {
    @Test func terminalOwnershipExpiresAcrossPersistenceSuspensions() {
        let handle = CodexTurnHandle()
        let began = handle.begin(turnID: "old", generation: handle.generation)
        let oldIntent = handle.intent
        handle.end()
        let replacement = handle.prepareReplacement()
        handle.finishReplacement(replacement)
        #expect(began)
        #expect(!handle.acceptsTerminal(turnID: "old", intent: oldIntent))
    }

    @Test func replacementSuppressesCompletionEvenAfterTheOldHandleEnded() {
        let handle = CodexTurnHandle()
        let began = handle.begin(turnID: "old", generation: handle.generation)
        let stopped = handle.markCancelled()
        handle.end()
        let replacement = handle.prepareReplacement()
        #expect(began)
        #expect(stopped.turnID == "old")
        #expect(!handle.acceptsTerminal(turnID: "old"))
        let nextBegan = handle.begin(turnID: "new", generation: handle.generation)
        handle.finishReplacement(replacement)
        #expect(nextBegan)
        #expect(!handle.acceptsTerminal(turnID: "old"))
        #expect(handle.acceptsTerminal(turnID: "new"))
    }

    @Test func stopInvalidatesAnInFlightStartButNotTheNextIntentionalOne() {
        let handle = CodexTurnHandle()
        let beforeStop = handle.generation
        handle.markCancelled()
        let late = handle.begin(turnID: "late", generation: beforeStop)
        let next = handle.begin(turnID: "new", generation: handle.generation)
        #expect(!late && next)
        #expect(handle.steerableTurnID == "new")
    }
}
