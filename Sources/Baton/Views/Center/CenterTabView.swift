import SwiftUI

/// The chrome every tab in the centre strip wears, whatever it holds.
///
/// A conversation, a shell and a web page have nothing in common except that the user switches
/// between them, so the switching is the only part they share. Height, hover, the rename editor
/// and the close button live here rather than in three places that would drift apart the first
/// time one of them was restyled.
///
/// The tab owns its own hover and its own rename field. The strip only says which tab is being
/// renamed, so two tabs can never both think they hold the editor.
struct CenterTabView: View {
    var title: String
    /// The kinds that need telling apart carry one; a chat tab does not, because it is what the
    /// strip is mostly made of and a glyph on every tab is noise rather than information.
    var icon: String?
    var isActive: Bool
    var isRunning = false
    var isRenaming: Bool
    /// What the rename field opens with. Kept apart from `title` because a session that has not
    /// been named yet shows "Untitled", and putting that word into the editor hands the user a
    /// name they never chose.
    var editableTitle: String
    var canClose: Bool
    /// What the close button and its context menu item call this tab, for VoiceOver and tooltips.
    var closeTitle: String
    var onSelect: @MainActor () -> Void
    var onStartRename: @MainActor () -> Void
    var onCommitRename: @MainActor (String) -> Void
    var onCancelRename: @MainActor () -> Void
    var onClose: @MainActor () -> Void
    /// Opening the tab beside the pane it is already in, for anyone who would rather pick a menu
    /// item than drag the tab into the half of the pane they want it in.
    var onSplitRight: @MainActor () -> Void
    var onSplitDown: @MainActor () -> Void

    /// A tab stops growing here so one long title cannot push every other tab out of the strip.
    private static let maximumWidth: CGFloat = 200
    /// Wide enough for the titles tabs actually get, and the same width whichever tab is being
    /// renamed, so the strip does not jump as the editor opens.
    private static let renameWidth: CGFloat = 140
    /// The row every tab centres in the strip. Fixed rather than intrinsic because a rename field
    /// is a point or two taller than a label, and a tab that grew as its editor opened put its
    /// text on a different line from the tabs beside it.
    private static let labelHeight: CGFloat = 20

    @State private var isHovered = false
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if isRunning {
                ActivityDot(isActive: true)
                    .accessibilityLabel("Running")
            }

            if let icon {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
            }

            if isRenaming {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($isRenameFocused)
                    .frame(width: Self.renameWidth)
                    .onSubmit { onCommitRename(renameText) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(title)
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            closeButton
        }
        // One type size for the whole row, set once above the branches, so selection can only
        // change the weight. Everything a tab can hold is then on the same line as everything a
        // neighbouring tab holds, whatever each of them is showing.
        .font(Typo.label)
        .frame(height: Self.labelHeight)
        .padding(.horizontal, Metrics.inset)
        .frame(maxWidth: Self.maximumWidth)
        .frame(height: Metrics.barHeight)
        // The selected tab takes the content colour and fills the strip's full height, the way an
        // editor tab bar on this platform does. A rounded capsule of selection grey floating in a
        // strip is a browser chrome idiom, and it read as a solid block rather than as a tab.
        //
        // The fill is opaque and reaches the bottom of the strip on purpose: the rule that closes
        // the strip off from the pane is painted BEHIND the tabs, so this covers it and the
        // selected tab runs into the content underneath rather than sitting in a box above it.
        .background(background)
        .contentShape(Rectangle())
        // A single click selects and a double click renames, which is one gesture with two
        // meanings rather than a button, so it cannot be expressed as one.
        .gesture(
            TapGesture(count: 2)
                .onEnded { onStartRename() }
                .exclusively(before: TapGesture().onEnded { onSelect() })
        )
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityAction(named: "Rename", onStartRename)
        .contextMenu {
            Button("Open in Split Right", action: onSplitRight)
            Button("Open in Split Down", action: onSplitDown)
            Divider()
            Button("Rename", action: onStartRename)
            Button("Close", action: onClose)
                .disabled(!canClose)
        }
        .task(id: isRenaming) { await startEditing() }
    }

    private var background: Color {
        if isActive { return Palette.surface }
        return isHovered ? Palette.hover : .clear
    }

    /// Kept in the layout even when it is invisible, so no label moves when the pointer enters.
    /// Shown on the selected tab as well as the hovered one, because the tab you are looking at is
    /// the one you are most likely to want to close.
    private var closeButton: some View {
        Button(action: onClose) {
            Label(closeTitle, systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!canClose)
        .help(closeTitle)
    }

    private var isVisible: Bool {
        canClose && (isHovered || isActive)
    }

    /// The field only exists from the moment the strip says so, and a brand new field cannot take
    /// focus in the same pass it is created in.
    private func startEditing() async {
        guard isRenaming else { return }
        renameText = editableTitle
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        isRenameFocused = true
    }
}
