import Testing
@testable import BloomClient

struct ComposerModelChoicesTests {
    @Test func unknownBackendModelsDoNotOfferUnsupportedReasoningControls() {
        let choices = ComposerModelChoices()
        #expect(choices.efforts(for: .grok, model: "grok-custom").isEmpty)
        #expect(!choices.efforts(for: .codex, model: "gpt-custom").isEmpty)
        #expect(!choices.efforts(for: .claudeCode, model: "opus").isEmpty)
    }

    @Test func fetchedBackendModelsShareSelectionAndTheirOwnEffortDefaults() {
        let grok = AgentModel(id: "grok-code-test", displayName: "Grok Code Test",
            supportedEfforts: [.init(id: "low", label: "Low"), .init(id: "high", label: "High")], defaultEffort: "low")
        let choices = ComposerModelChoices(models: [.grok: [grok]], availableAgents: [.grok])
        #expect(choices.sections(includingCurrent: grok.id, on: .grok).map(\.kind) == [.grok])
        #expect(choices.options(for: .grok).map(\.id) == [grok.id])
        #expect(choices.efforts(for: .grok, model: grok.id).map(\.id) == ["low", "high"])
        #expect(choices.resolvedEffort("max", for: .grok, model: grok.id) == "low")
        let selected = choices.selecting("grok:" + grok.id, in: ComposerControls(model: "opus", effort: "max"))
        #expect(selected.agentKind == .grok && selected.model == grok.id && selected.effort == "low")
    }

    @Test func hiddenFetchedModelsStayHiddenUnlessThisConversationAlreadyUsesOne() {
        let visible = AgentModel(id: "gpt-visible", displayName: "Visible")
        let hidden = AgentModel(id: "gpt-hidden", displayName: "Hidden", hidden: true)
        let choices = ComposerModelChoices(models: [.codex: [visible, hidden]], availableAgents: [.codex])
        #expect(choices.options(for: .codex).map(\.id) == [visible.id])
        #expect(choices.sections(includingCurrent: hidden.id, on: .codex).first?.options.contains { $0.id == hidden.id } == true)
    }
}
