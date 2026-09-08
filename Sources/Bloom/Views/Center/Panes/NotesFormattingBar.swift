import SwiftUI
import BloomCore

/// Familiar formatting actions, with Markdown source available for direct editing.
struct NotesFormattingBar: View {
    var commands: NotesFormattingCommands
    var isEditing: Bool
    @Binding var showsSource: Bool
    @State private var showsLink = false
    @State private var linkURL = ""
    @FocusState private var isURLFocused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacingSmall) {
                Menu {
                    ForEach(1...3, id: \.self) { level in
                        Button("Heading \(level)") { commands.apply(.heading(level)) }
                    }
                } label: {
                    Label("Heading", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                }
                .help("Heading")

                button("Bold", symbol: "bold", action: .bold, shortcut: "b")
                button("Italic", symbol: "italic", action: .italic, shortcut: "i")
                button("Inline code", symbol: "chevron.left.forwardslash.chevron.right", action: .code)

                Divider().frame(height: 14).padding(.horizontal, Metrics.spacingSmall)

                Menu {
                    Button("Bulleted list", systemImage: "list.bullet") { commands.apply(.bulletList) }
                    Button("Numbered list", systemImage: "list.number") { commands.apply(.numberedList) }
                } label: {
                    Label("List", systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                }
                .help("List")

                Button {
                    linkURL = ""
                    showsLink = true
                } label: {
                    Label("Link", systemImage: "link")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .help("Insert link")
                .keyboardShortcut(isEditing ? KeyboardShortcut("k", modifiers: .command) : nil)
                .popover(isPresented: $showsLink) { linkPopover }

                Menu {
                    Button("Code block", systemImage: "curlybraces") { commands.apply(.codeBlock) }
                    Button("Quote", systemImage: "text.quote") { commands.apply(.quote) }
                } label: {
                    Label("More formatting", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .help("More formatting")

                Divider().frame(height: 14).padding(.horizontal, Metrics.spacingSmall)

                Toggle("Source", isOn: $showsSource)
                    .toggleStyle(.button)
                    .help("Show the Markdown syntax")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
            .padding(.vertical, Metrics.spacingSmall)
        }
        .frame(height: Metrics.barHeight)
    }

    private func button(_ title: String, symbol: String, action: NoteFormatting.Action, shortcut: KeyEquivalent? = nil) -> some View {
        Button { commands.apply(action) } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .help(title)
        .keyboardShortcut(isEditing ? shortcut.map { KeyboardShortcut($0, modifiers: .command) } : nil)
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: Metrics.inset) {
            Text("Insert link").font(Typo.bodyEmphasis)
            TextField("https://example.com", text: $linkURL)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFocused)
                .onSubmit(insertLink)
                .onExitCommand { showsLink = false }
            HStack {
                Spacer()
                Button("Insert link", action: insertLink)
                    .buttonStyle(.borderedProminent)
                    .disabled(linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Metrics.pane)
        .frame(width: 300)
        .task { isURLFocused = true }
    }

    private func insertLink() {
        let url = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        showsLink = false
        commands.apply(.link(url))
    }
}
