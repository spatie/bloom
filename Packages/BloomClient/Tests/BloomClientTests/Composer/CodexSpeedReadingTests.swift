import Foundation
import Testing
@testable import BloomClient

struct CodexSpeedReadingTests {
    private let fast = CodexSpeed(isFast: true, supportsFast: true)

    @Test func olderServerStateDecodesWithoutSpeedsAndReadsAsUnavailable() throws {
        let legacy = try JSONDecoder().decode(RemoteComposerState.self, from: JSONEncoder().encode(
            RemoteComposerState(controls: ComposerControls(model: "gpt-test", agentKind: .codex))))
        #expect(legacy.codexSpeeds == nil)
        #expect(legacy.codexSpeed(for: "gpt-test") == .unavailable)
    }

    @Test func serverSpeedsRoundTripAndFollowTheSelectedModel() throws {
        let state = RemoteComposerState(controls: ComposerControls(model: "gpt-test", agentKind: .codex),
            codexSpeeds: ["gpt-test": fast, "gpt-slow": .init(isFast: false, supportsFast: false)])
        let decoded = try JSONDecoder().decode(RemoteComposerState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.codexSpeed(for: "gpt-test") == .read(fast))
        #expect(decoded.codexSpeed(for: "gpt-slow").speed?.supportsFast == false)
        #expect(decoded.codexSpeed(for: "gpt-unknown") == .unavailable)
    }

    @Test func notYetLoadedIsLoadingRatherThanUnavailable() {
        #expect(CodexSpeedReading.reported(["gpt-test": fast], model: "gpt-test", isLoaded: false) == .loading)
        #expect(CodexSpeedReading.reported(nil, model: "gpt-test", isLoaded: false) == .loading)
    }

    @Test func speedsCoverEveryModelUnderOneConfiguration() {
        let models = [CodexModel(id: "a", displayName: "A", fastServiceTier: "priority"), CodexModel(id: "b", displayName: "B")]
        let speeds = CodexSpeed.speeds(config: .object(["service_tier": .string("fast")]), models: models)
        #expect(speeds["a"] == CodexSpeed(isFast: true, supportsFast: true))
        #expect(speeds["b"] == CodexSpeed(isFast: false, supportsFast: false))
    }
}
