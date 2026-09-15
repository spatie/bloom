import Foundation
import Testing
@testable import BloomCore

@Suite struct CodexSpeedTests {
    private let model = CodexModel(
        id: "test-model", displayName: "Test", fastServiceTier: "priority"
    )

    @Test func decodesAdvertisedServiceTiers() throws {
        let model = try #require(CodexModel.decode(.object([
            "id": .string("test"),
            "serviceTiers": .array([.object(["id": .string("priority")])]),
            "defaultServiceTier": .string("priority"),
        ])))
        #expect(model.fastServiceTier == "priority")
        #expect(CodexSpeed(config: .object([:]), model: model).isFast)
        let legacy = try #require(CodexModel.decode(.object([
            "id": .string("legacy"), "additionalSpeedTiers": .array([.string("fast")]),
        ])))
        #expect(legacy.fastServiceTier == "priority")
    }

    @Test(arguments: ["fast", "priority"])
    func inheritsConfiguredFastMode(tier: String) {
        let speed = CodexSpeed(config: .object(["service_tier": .string(tier)]), model: model)
        #expect(speed.isFast)
        #expect(speed.supportsFast)
        #expect(speed.isFast(override: nil))
        #expect(!speed.isFast(override: false))
    }

    @Test func standardOverridesModelDefault() {
        let model = CodexModel(id: "test", displayName: "Test", fastServiceTier: "priority",
                               defaultServiceTier: "priority")
        #expect(CodexSpeed(config: .object([:]), model: model).isFast)
        #expect(!CodexSpeed(config: .object(["service_tier": .string("default")]), model: model).isFast)
    }

    @Test func unavailableFastModeIsNotShownAsEnabled() {
        let disabled = CodexSpeed(config: .object([
            "service_tier": .string("fast"),
            "features": .object(["fast_mode": .bool(false)]),
        ]), model: model)
        #expect(!disabled.supportsFast)
        #expect(!disabled.isFast(override: true))
        let unsupported = CodexSpeed(config: .object(["service_tier": .string("fast")]),
                                     model: CodexModel(id: "test", displayName: "Test"))
        #expect(!unsupported.isFast)
    }

    @Test func explicitOffSurvivesSavingControls() async throws {
        let store = try Store(path: ":memory:")
        let sessionID = SessionID("speed-test")
        var controls = ComposerControls(agentKind: .codex, isFastMode: true)
        #expect(controls.codexFastMode == nil)
        controls.codexFastMode = false
        await controls.store(sessionID: sessionID, in: store)
        #expect(try await store.setting(CodexSpeed.key(sessionID: sessionID)) == "0")
        #expect(CodexSpeed.override(stored: "0") == false)
        #expect(CodexSpeed.override(stored: nil) == nil)
    }

    @Test func readsMergedConfigurationForTheProject() async throws {
        let box = ProcessBox()
        box.reply(to: "config/read", with: .object([
            "config": .object(["service_tier": .string("fast")]),
        ]))
        let client = CodexClient(configuration: .init(cwd: "/tmp/project"), makeProcess: box.factory)
        try await client.start()
        let config = try await client.readConfiguration(cwd: "/tmp/project")
        #expect(CodexSpeed(config: config, model: model).isFast)
        let frame = try #require(box.process.sentFrame { $0["method"]?.stringValue == "config/read" })
        #expect(frame["params"]?["cwd"]?.stringValue == "/tmp/project")
        #expect(!box.process.sentMethods.contains("config/value/write"))
        await client.stop()
    }
}
