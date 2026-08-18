import AppIntents

/// Brings Bloom forward on a workspace, so a Shortcut can end by putting the work on screen.
struct OpenWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Workspace"

    static let description = IntentDescription(
        "Brings Bloom to the front and selects a workspace.",
        categoryName: "Workspaces"
    )

    static let openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$workspace) in Bloom")
    }

    func perform() async throws -> some IntentResult {
        guard await RunningApp.waitUntilReady() else { throw IntentFailure.appNeverAppeared }
        await RunningApp.select(workspaceID: workspace.id)
        return .result()
    }
}
