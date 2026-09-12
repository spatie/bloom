import Testing
@testable import BloomCore

@Suite struct AgentModelTests {
    private let codex = CodexModel(
        id: "shared", displayName: "Shared model", isDefault: true, hidden: true,
        supportedEfforts: [.init(id: "low"), .init(id: "xhigh")], defaultEffort: "low"
    )
    private let grok = GrokModel(
        id: "grok-test", displayName: "Grok Test", isDefault: true,
        supportedEfforts: [.init(id: "medium"), .init(id: "xhigh")], defaultEffort: "medium"
    )

    @Test func adaptersPreservePickerAndEffortMetadata() {
        let models = [codex.agentModel, grok.agentModel]
        #expect(models.map(\.id) == ["shared", "grok-test"])
        #expect(models.map(\.displayName) == ["Shared model", "Grok Test"])
        #expect(models.allSatisfy { $0.isDefault })
        #expect(models.map(\.hidden) == [true, false])
        #expect(models.map { $0.supportedEfforts.last?.label } == ["Extra high", "Extra high"])
        #expect(models.map { $0.resolvedEffort(preferring: "xhigh") } == ["xhigh", "xhigh"])
        #expect(models.map { $0.resolvedEffort(preferring: "max") } == ["low", "medium"])
    }

    @Test func selectionUsesVisibleDefaultsAndNeverReplacesAnExplicitChoice() {
        let first = AgentModel(id: "first", displayName: "First")
        let models = [codex.agentModel, first, grok.agentModel]
        #expect(AgentModel.selection(requested: nil, from: models)?.id == "grok-test")
        #expect(AgentModel.selection(requested: "first", from: models)?.id == "first")
        #expect(AgentModel.selection(requested: "unknown", from: models) == nil)
        #expect(AgentModel.selection(requested: "shared", from: models) == nil)
        #expect(AgentModel.selection(requested: nil, from: [codex.agentModel, first])?.id == "first")
        #expect(AgentModel.selection(requested: nil, from: [codex.agentModel]) == nil)
    }

    @Test func effortFallsBackToFirstLevelOrEmptyWhenNoDefaultExists() {
        let model = AgentModel(
            id: "test", displayName: "Test", supportedEfforts: [.init(id: "low", label: "Low")]
        )
        #expect(model.resolvedEffort(preferring: "unknown") == "low")
        #expect(AgentModel(id: "none", displayName: "None").resolvedEffort(preferring: "high") == "")
    }

    @Test func fetchedModelsResolveNamesAndEffortsForTheirOwnBackend() {
        let models: [AgentKind: [AgentModel]] = [.codex: [codex.agentModel], .grok: [grok.agentModel]]
        let identity = ModelIdentifier.resolve("Grok: Grok Test", models: models)
        #expect(identity == ModelIdentifier(model: "grok-test", kind: .grok, namesBackend: true))
        #expect(DefaultBackend.effort("max", on: .grok, model: "grok-test", models: models) == "medium")
        #expect(DefaultBackend.effort("max", on: .codex, model: "grok-test", models: models) == "max")
        #expect(ModelIdentifier.resolve("Shared model", models: models).model == "shared")
    }

    @Test func backendOrderAndExplicitNamespaceResolveOverlappingModelIDs() {
        let model = AgentModel(id: "shared", displayName: "Shared")
        let models: [AgentKind: [AgentModel]] = [.grok: [model], .codex: [model]]
        #expect(ModelIdentifier.resolve("shared", models: models).kind == .codex)
        #expect(ModelIdentifier.resolve("grok:shared", models: models).kind == .grok)
    }
}
