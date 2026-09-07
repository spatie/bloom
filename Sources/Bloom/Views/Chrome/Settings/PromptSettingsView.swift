import SwiftUI
import BloomCore

struct PromptSettingsView: View {
    @State private var selection: PromptID? = .createPullRequest
    @State private var customised: Set<PromptID> = []

    private var definition: PromptDefinition {
        PromptRegistry.definition(for: selection ?? .createPullRequest)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("Workflow prompts")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Metrics.inset)
                    .padding(.top, Metrics.inset)

                List(selection: $selection) {
                    ForEach(PromptRegistry.all) { prompt in
                        HStack(spacing: Metrics.spacingSmall) {
                            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                                Text(prompt.title)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if customised.contains(prompt.id) {
                                    Text("Customised")
                                        .font(Typo.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 0)

                            // Native selection can fade when focus moves to the editor. Keep a
                            // shape as well as colour so the prompt being edited stays apparent.
                            Image(systemName: "checkmark")
                                .font(Typo.captionEmphasis)
                                .opacity(selection == prompt.id ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, Metrics.spacingSmall)
                        .tag(prompt.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Workflow prompts")
            }
            .frame(width: 210)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gutter) {
                    VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                        Text(definition.title)
                            .font(Typo.bodyEmphasis)
                        Text(customised.contains(definition.id) ? "Customised prompt" : "Built-in prompt")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }

                    PromptEditor(definition: definition) {
                        refreshStatuses()
                    }
                    // A different prompt must never inherit the previous editor's draft or focus.
                    .id(definition.id)

                    Text("Changes save automatically and apply the next time Bloom uses this prompt.")
                        .settingsFootnote()
                }
                .padding(Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: refreshStatuses)
    }

    private func refreshStatuses() {
        let overrides = PromptOverrides()
        customised = Set(PromptRegistry.all.filter { overrides.isCustomised(for: $0.id) }.map(\.id))
    }
}
