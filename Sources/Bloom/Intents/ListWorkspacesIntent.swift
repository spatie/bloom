import AppIntents
import BloomCore

/// Every workspace, with enough on each one for a Shortcut to decide what to do next.
struct ListWorkspacesIntent: AppIntent {
    static let title: LocalizedStringResource = "List Workspaces"

    static let description = IntentDescription(
        """
        Returns Bloom's workspaces with their status and diff size. Reads Bloom's database \
        directly, so it answers whether or not Bloom is open.
        """,
        categoryName: "Workspaces",
        resultValueName: "Workspaces"
    )

    @Parameter(
        title: "Only Where an Agent Is Running",
        description: "Narrows the answer to the workspaces with a turn open right now.",
        default: false
    )
    var onlyRunning: Bool

    @Parameter(
        title: "Ask GitHub",
        description: "Includes pull request state. Costs one gh call per workspace, so it is slow on a long list.",
        default: false
    )
    var includePullRequests: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get Bloom workspaces") {
            \.$onlyRunning
            \.$includePullRequests
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[WorkspaceEntity]> {
        let store = try await IntentDatabase.store()
        let entities = try await WorkspaceLookup.entities(
            for: try await store.workspaces(),
            store: store,
            includePullRequests: includePullRequests
        )
        let answer = onlyRunning ? entities.filter(\.isAgentRunning) : entities
        return .result(value: answer, dialog: dialog(for: answer))
    }

    /// Spoken from Spotlight, "12 workspaces" is not the answer anybody wanted. How many of them
    /// are working is.
    private func dialog(for entities: [WorkspaceEntity]) -> IntentDialog {
        let running = entities.count(where: \.isAgentRunning)
        if entities.isEmpty { return "Bloom has no workspaces." }
        let workspaces = entities.count == 1 ? "1 workspace" : "\(entities.count) workspaces"
        if onlyRunning { return "\(workspaces) with an agent running." }
        return running == 0
            ? "\(workspaces), none of them working."
            : "\(workspaces), \(running) with an agent running."
    }
}
