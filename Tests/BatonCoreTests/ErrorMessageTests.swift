import Testing
import Foundation
@testable import BatonCore

@Suite("Error messages")
struct ErrorMessageTests {
    @Test("Baton's own errors keep the sentence they wrote")
    func usesOwnDescription() {
        let error = WorkspaceError.notARepository("/tmp/nope")
        #expect(error.readableMessage == "/tmp/nope is not a git repository.")
    }

    @Test("a fragment is shown as a sentence")
    func shapesAFragment() {
        struct Fragment: Error, CustomStringConvertible { let description = "not a directory" }
        #expect(Fragment().readableMessage == "Not a directory.")
    }

    @Test("a message that already ends in punctuation is left alone")
    func leavesAFinishedSentence() {
        struct Done: Error, CustomStringConvertible { let description = "The file is missing." }
        #expect(Done().readableMessage == "The file is missing.")
    }

    @Test("a system error reads as its localised description, not its domain and code")
    func usesLocalizedDescription() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file could not be opened."]
        )
        #expect(error.readableMessage == "The file could not be opened.")
    }

    @Test("an error nobody localised falls back to something specific rather than a code")
    func fallsBackToTheValue() {
        enum Sample: Error { case cannotReachTheServer }
        let message = Sample.cannotReachTheServer.readableMessage
        #expect(message.contains("cannotReachTheServer"))
        #expect(!message.contains("error 0"))
    }
}
