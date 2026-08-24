import SwiftUI
import BloomCore

/// The wording Bloom sends to a coding agent when a button in the app stands in for a sentence the
/// user would otherwise have typed.
///
/// The form is generated from `PromptRegistry.all` rather than written out per prompt, so a second
/// prompt is one entry in that array and no work here at all.
struct PromptSettingsView: View {
    /// Read once into view state rather than through the wrapper on every draw, so toggling it
    /// redraws the row it is on.
    @State private var namesWorkspaces = WorkspaceNamingPreferences().isEnabled

    var body: some View {
        Form {
            Section {
                Text("""
                Some buttons in Bloom do their work by asking the workspace's agent, rather than \
                running the command themselves. The agent already knows this project's commit \
                conventions and its pull request template, which Bloom does not. These are the \
                words it is sent. Each request appears in the transcript and streams back like \
                anything you type yourself.
                """)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(PromptRegistry.all) { definition in
                Section(definition.title) {
                    // The one prompt with a switch, because it is the one Bloom sends without
                    // being pressed. It sits above the template rather than in a settings pane of
                    // its own, so the thing being switched off and the words being sent are read
                    // together.
                    if definition.id == .nameWorkspace {
                        Toggle("Name new workspaces automatically", isOn: $namesWorkspaces)
                            .onChange(of: namesWorkspaces) { _, value in
                                WorkspaceNamingPreferences().isEnabled = value
                            }

                        Text("""
                        A new workspace is created under a plant name and renamed a few seconds \
                        later, along with its branch where that is still safe. Doing it sends the \
                        text of your first message to Claude, through the same `claude` command \
                        and the same account the workspace's own agent uses, in a separate \
                        request with no tools and no access to your code. Turn this off and a \
                        workspace is named from the first line of your message, as it always was.
                        """)
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    PromptEditor(definition: definition)
                }
            }
        }
        .settingsForm()
    }
}
