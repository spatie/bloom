import Foundation
import Testing
@testable import BloomCore

/// `Bloom --open-url` is a harness affordance, and a harness that silently drops its argument is
/// worse than no harness: the run looks like the deep link machinery failed. These pin the repair
/// that keeps an unencoded prompt alive, and the pass-through that keeps an encoded one exact.
@Suite("Opening a URL given on the command line")
struct OpenURLArgumentTests {
    @Test("a properly encoded link is passed through byte for byte")
    func encodedLinkIsUntouched() {
        let argument = "bloom://prompt=fix%20the%20bug&path=/tmp/x"
        #expect(OpenURLArgument.url(from: argument)?.absoluteString == argument)
    }

    @Test("a colon in the prompt no longer loses the whole link")
    func colonSurvives() throws {
        let url = try #require(
            OpenURLArgument.url(from: "bloom://prompt=fix: the bug&path=/tmp/x")
        )
        #expect(url.scheme == "bloom")
        #expect(url.absoluteString == "bloom://prompt=fix%3A%20the%20bug&path=%2Ftmp%2Fx")
    }

    @Test("a repaired prompt decodes back to exactly what was typed")
    func repairedPromptRoundTrips() throws {
        let typed = "fix: the bug, 100% of the time + tests"
        let url = try #require(OpenURLArgument.url(from: "bloom://prompt=\(typed)&path=/tmp/x"))

        // Read back the way `BloomDeepLink.values(from:)` reads it: split on & and =, then map
        // + to space and remove the percent encoding. A literal + and a literal % in the typed
        // text have to survive that decoding, which is why the repair encodes both.
        let payload = url.absoluteString.replacing("bloom://", with: "")
        let pairs = payload.split(separator: "&").map {
            $0.split(separator: "=", maxSplits: 1).map(String.init)
        }
        let prompt = try #require(pairs.first { $0.first == "prompt" }?.last)
        #expect(prompt.replacing("+", with: " ").removingPercentEncoding == typed)
    }

    @Test("the pair structure is kept, so the path stays its own value")
    func pairsAreKept() throws {
        let url = try #require(
            OpenURLArgument.url(from: "bloom://prompt=do the thing&path=/Users/x/dev/repo")
        )
        let payload = url.absoluteString.replacing("bloom://", with: "")
        let keys = payload.split(separator: "&").map { String($0.split(separator: "=")[0]) }
        #expect(keys == ["prompt", "path"])
    }

    @Test("text with no scheme is refused rather than guessed at", arguments: [
        "", "fix the bug", "://prompt=x", "1bad://prompt=x", "no scheme here: none",
    ])
    func schemelessTextIsRefused(argument: String) {
        #expect(OpenURLArgument.url(from: argument) == nil)
    }

    @Test("the dev scheme repairs under its own name, not under bloom's")
    func otherSchemesRepairToo() throws {
        let url = try #require(OpenURLArgument.url(from: "bloomdev://prompt=two words&path=/t"))
        #expect(url.scheme == "bloomdev")
    }
}
