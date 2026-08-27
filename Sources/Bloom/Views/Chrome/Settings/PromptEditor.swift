import SwiftUI
import BloomCore

/// One editable prompt: the text, what may be substituted into it, and the way back to the built-in.
///
/// The box always shows what would actually be sent, so there is no second state where the field
/// looks empty but a default is quietly in use. The one exception is a prompt the user has emptied
/// on purpose: that is shown as empty, because hiding it would look like the deletion failed, and
/// it still falls back to the built-in on the way out.
struct PromptEditor: View {
    let definition: PromptDefinition

    /// Tall enough that the built-in prompts are readable without scrolling on a default window,
    /// and short enough that the variable reference below stays visible.
    private static let editorHeight: CGFloat = 220

    /// Drawn inside the box's own edge rather than outside it, so nothing around it has to give
    /// the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    private let overrides = PromptOverrides()

    /// Closed. The tokens are a reference somebody reaches for while editing, not an explanation
    /// of the setting, and seven prompts each showing five of them was most of the pane's height
    /// spent on a table nobody had asked to see.
    @State private var showsVariables = false

    @State private var text = ""
    /// Until the stored value has been read, `text` is an empty string that nobody typed. Writing
    /// that back would turn every visit to this tab into an override.
    @State private var isLoaded = false

    @FocusState private var isFocused: Bool

    /// See `ControlActiveState.showsFocusRing`: a ring belongs in the key window only.
    @Environment(\.controlActiveState) private var activeState

    /// Focused, and in the window the keys are going to.
    private var isRingVisible: Bool { isFocused && activeState.showsFocusRing }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text(definition.summary)
                .settingsFootnote()

            editor

            HStack(spacing: Metrics.gutter) {
                status

                Spacer()

                Button("Restore default", action: restoreDefault)
                    .disabled(!isCustomised)
            }

            if !unknownVariables.isEmpty {
                Label(
                    "Not substituted: \(unknownVariables.map(PromptTemplate.token).joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                // Opened for them, because a token that will not be substituted is the one moment
                // the list of the ones that will is worth interrupting for.
                .onAppear { showsVariables = true }
            }

            variableReference
        }
        .task { load() }
        .onChange(of: text) { _, value in save(value) }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(Typo.codeSmall)
            .scrollContentBackground(.hidden)
            .padding(Metrics.spacingSmall)
            .frame(minHeight: Self.editorHeight)
            .focused($isFocused)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            // A hand-built box gets no focus ring from AppKit, and a field that looks identical
            // whether or not it has the keyboard is the single most reliable way to make a Mac
            // window feel like a web page. The same overlay `HomeBar`'s search field uses, in the
            // same colour macOS draws a real one in, so it follows Full Keyboard Access and
            // Increase Contrast with it.
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(
                        isRingVisible ? Palette.focusRing : Palette.border,
                        lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.outline
                    )
            }
            .accessibilityLabel("\(definition.title) prompt")
    }

    @ViewBuilder
    private var status: some View {
        if isEmptyOverride {
            Text("Empty, so the built-in prompt is sent.")
                .settingsFootnote()
        } else if isCustomised {
            Text("Customised")
                .settingsFootnote()
        }
    }

    /// The tokens, behind a disclosure.
    ///
    /// Not deleted, because it is the one thing on the row a person editing a template genuinely
    /// reaches for, and not open, because it is reference rather than explanation: five rows times
    /// seven prompts was the tallest thing on the pane and none of it had been asked for.
    private var variableReference: some View {
        DisclosureGroup(isExpanded: $showsVariables) {
            // A grid rather than a list of `LabeledContent`, so the tokens line up as a reference
            // table instead of hugging opposite edges of a wide settings window.
            Grid(alignment: .leading, horizontalSpacing: Metrics.gutter, verticalSpacing: Metrics.spacingSmall) {
                ForEach(definition.variables) { variable in
                    GridRow {
                        Text(variable.token)
                            .font(Typo.codeSmall)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)

                        Text(variable.summary)
                            .settingsFootnote()
                    }
                }
            }
            .padding(.top, Metrics.spacingSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Variables")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - State

    private var isCustomised: Bool {
        text != definition.defaultTemplate
    }

    private var isEmptyOverride: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Anything in braces the prompt cannot fill. Reported rather than corrected, because the token
    /// survives into the message and a typo is far easier to see here than in a transcript.
    private var unknownVariables: [String] {
        let declared = Set(definition.variables.map(\.name))
        return PromptTemplate.variableNames(in: text).filter { !declared.contains($0) }
    }

    // MARK: - Storage

    private func load() {
        text = overrides.stored(for: definition.id) ?? definition.defaultTemplate
        isLoaded = true
    }

    /// Text identical to the built-in is stored as no override at all, so a prompt that later ships
    /// with better wording picks it up rather than staying pinned to the copy this user happened to
    /// have on screen once.
    private func save(_ value: String) {
        guard isLoaded else { return }
        overrides.set(value == definition.defaultTemplate ? nil : value, for: definition.id)
    }

    private func restoreDefault() {
        text = definition.defaultTemplate
    }
}
