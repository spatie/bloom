import Testing
import Foundation
@testable import BloomCore

private actor ModelFetch {
    var attempts = 0

    func fetch() throws -> [GrokModel] {
        attempts += 1
        if attempts == 1 { throw GrokClientError.notInitialized }
        return [GrokModel(id: "grok-test", displayName: "Test")]
    }
}

@Suite(.scratchDirectory)
struct GrokModelCatalogTests {
    @Test("a failed discovery is retried and the successful result is cached")
    func retryAfterFailure() async throws {
        let source = ModelFetch()
        let catalog = GrokModelCatalog(fetch: { try await source.fetch() })
        await #expect(throws: GrokClientError.notInitialized) {
            try await catalog.models()
        }
        let models = try await catalog.models()
        let cached = try await catalog.models()
        #expect(models.map(\.id) == ["grok-test"])
        #expect(cached == models)
        #expect(await source.attempts == 2)
    }

    @Test("discovery reads the executable override again after invalidation")
    func configuredExecutable() async throws {
        let store = try makeTestStore("grok-catalog-executable")
        let key = AgentCatalog.executablePathSettingKey(.grok)
        try await store.setSetting(key, "/tmp/custom grok")
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object(["_meta": .object([
            "modelState": .object(["availableModels": .array([
                .object(["modelId": .string("grok-test"), "name": .string("Test")]),
            ])]),
        ])]))
        let catalog = GrokModelCatalog.live(cwd: "/tmp/w", store: store, makeClient: { configuration in
            GrokClient(configuration: configuration, makeProcess: box.factory)
        })
        let models = try await catalog.pickerModels()
        #expect(models.map(\.id) == ["grok-test"])
        #expect(box.process.launch.executable == "/tmp/custom grok")
        try await store.setSetting(key, "/tmp/replacement grok")
        await catalog.invalidate()
        _ = try await catalog.pickerModels()
        #expect(box.process.launch.executable == "/tmp/replacement grok")
    }
}
