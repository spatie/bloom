import AppIntents

/// The phrases that work from Spotlight without anybody building a Shortcut first.
///
/// Only the intent with no required parameters is offered here. An App Shortcut has to be
/// runnable from a spoken phrase alone, and "create a workspace" needs a project and a prompt that
/// no phrase can supply, so that one stays a Shortcuts action where the picker can ask for both.
struct BatonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListWorkspacesIntent(),
            phrases: [
                "List \(.applicationName) workspaces",
                "What is running in \(.applicationName)",
                "\(.applicationName) workspaces",
            ],
            shortTitle: "List Workspaces",
            systemImageName: "square.stack.3d.up"
        )
    }
}
