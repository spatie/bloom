import SwiftUI
import BloomCore

/// The wording Bloom sends to a coding agent when a button in the app stands in for a sentence the
/// user would otherwise have typed.
///
/// **The pane used to open with this paragraph, and that is why it is here instead.** Some buttons
/// in Bloom do their work by asking the workspace's agent rather than running the command
/// themselves, because the agent already knows this project's commit conventions and its pull
/// request template and Bloom does not. Each request lands in the transcript and streams back like
/// anything typed into the composer. On screen it was four lines of grey prose above a second five
/// line box above the one short field somebody had come to edit; a reader of this file needs it and
/// a person changing a setting does not. The argument for asking an agent at all, rather than
/// shelling out to `gh`, is on `PromptRegistry`.
///
/// What is left on the pane is one line per prompt, saying which button sends it and which
/// instruction file rides along, which is what somebody editing the template actually has to know.
///
/// The form is generated from `PromptRegistry.all` rather than written out per prompt, so a second
/// prompt is one entry in that array and no work here at all.
struct PromptSettingsView: View {
    /// Read once into view state rather than through the wrapper on every draw, so toggling it
    /// redraws the row it is on.
    @State private var namesWorkspaces = WorkspaceNamingPreferences().isEnabled

    var body: some View {
        Form {
            ForEach(PromptRegistry.all) { definition in
                Section(definition.title) {
                    if definition.id == .nameWorkspace {
                        namingToggle
                    }

                    PromptEditor(definition: definition)
                }
            }
        }
        .settingsForm()
    }

    /// The one prompt with a switch, because it is the one Bloom sends without being pressed. It
    /// sits above the template rather than in a settings pane of its own, so the thing being
    /// switched off and the words being sent are read together.
    ///
    /// One secondary line, and it is the privacy fact rather than the mechanism: the message goes
    /// to Claude outside the workspace's own session. That is the sentence somebody deciding this
    /// needs. What happens with the switch off is a tooltip, and the plant name it wears in the
    /// meantime is on `PromptRegistry.nameWorkspace`.
    private var namingToggle: some View {
        Toggle(isOn: $namesWorkspaces) {
            Text("Name new workspaces automatically")
            Text("Sends your first message to Claude on its own, with no tools and no access to your code.")
        }
        .help("With this off, a workspace is named from the first line of your message, as it always was.")
        .onChange(of: namesWorkspaces) { _, value in
            WorkspaceNamingPreferences().isEnabled = value
        }
    }
}
