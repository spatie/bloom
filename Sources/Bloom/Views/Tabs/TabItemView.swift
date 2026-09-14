import SwiftUI

/// The chrome every tab in Bloom wears, whatever it holds and whichever strip it is in.
///
/// A conversation, a shell, a web page, a setup log and a run script have nothing in common except
/// that the user switches between them, so the switching is the only part they share. Height,
/// hover, the rename editor and the close button live here rather than in five places that would
/// drift apart the first time one of them was restyled. The bottom panel used to draw its own,
/// which is how it ended up with square corners, a different rename field and no outline while the
/// centre column was being measured against Safari.
///
/// The tab owns its own hover and its own rename field. The strip only says which tab is being
/// renamed, so two tabs can never both think they hold the editor.
struct TabItemView: View {
    var title: String
    /// Every kind carries one, including a chat: a strip with a glyph on two tabs of three reads
    /// as a row that has lost an icon. Still optional, because the bottom panel's setup log and
    /// run scripts are named after the script and have nothing to add.
    ///
    /// A `TabItemIcon` rather than a symbol name, because a browser tab wears the page's own
    /// favicon and that is a picture rather than a glyph. See `TabItemIcon`.
    var icon: TabItemIcon?
    var isActive: Bool
    var isRunning = false
    /// The ground of the pane this tab opens and the ink that reads on it, worn while the tab is
    /// the selected one. `TabPane.content.surface` for the centre column, `.sunken` for the bottom
    /// panel, and the user's own Ghostty colours for a terminal running their theme.
    var surface: TabSurface = TabPane.content.surface
    var isRenaming: Bool
    /// What the rename field opens with. Kept apart from `title` because a session that has not
    /// been named yet shows "Untitled", and putting that word into the editor hands the user a
    /// name they never chose.
    var editableTitle: String
    var canClose: Bool
    /// Whether double clicking the tab opens a name field. A review is named after the file it is
    /// showing, so a name of the reader's own would be overwritten the moment they clicked
    /// another one.
    var canRename = true
    /// What the close button and its context menu item call this tab, for VoiceOver and tooltips.
    var closeTitle: String
    var onSelect: @MainActor () -> Void
    var onStartRename: @MainActor () -> Void
    var onCommitRename: @MainActor (String) -> Void
    var onCancelRename: @MainActor () -> Void
    var onClose: @MainActor () -> Void
    /// Opening the tab beside the pane it is already in, for anyone who would rather pick a menu
    /// item than drag the tab into the half of the pane they want it in.
    ///
    /// Absent in the bottom panel, which is one pane and cannot be split from its strip: a
    /// terminal there splits inside its own view. The menu items go with them rather than being
    /// shown greyed, because a permanently disabled item is a worse answer than no item.
    var onSplitRight: (@MainActor () -> Void)?
    var onSplitDown: (@MainActor () -> Void)?
    /// The strip's namespace, so the selected tab's fill is one view that moves rather than one
    /// that is destroyed here and built again over there. Without it the highlight blinks from
    /// tab to tab, and a highlight that blinks is the single clearest tell that a tab strip was
    /// drawn rather than grown.
    var namespace: Namespace.ID

    /// Short titles still need enough room to read as tabs and keep the close target clear.
    static let minimumWidth: CGFloat = 110
    /// A standalone tab preview has no strip to assign its width.
    private static let maximumWidth: CGFloat = 200
    /// Wide enough for the titles tabs actually get, and the same width whichever tab is being
    /// renamed, so the strip does not jump as the editor opens.
    private static let renameWidth: CGFloat = 140
    /// The row every tab centres in the strip. Fixed rather than intrinsic because a rename field
    /// is a point or two taller than a label, and a tab that grew as its editor opened put its
    /// text on a different line from the tabs beside it.
    private static let labelHeight: CGFloat = 20
    /// Native window tabs use a 24-point capsule inside their track.
    static let tabHeight: CGFloat = 24
    /// One highlight for the whole strip, so `matchedGeometryEffect` has something to match on.
    private static let selectionID = "tabItem.selection"

    private static let closeSize: CGFloat = 20

    @Environment(\.tabItemWidth) private var tabItemWidth
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appearsActive) private var appearsActive

    @State private var isHovered = false
    /// The pointer on the close cross itself rather than on the tab around it.
    ///
    /// See the tap gestures below: this is what keeps a click on the cross from also selecting.
    @State private var isCloseHovered = false
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Activity replaces the glyph in a fixed slot, so the title stays still as work starts.
            if icon != nil || isRunning {
                ZStack {
                    if isRunning {
                        ActivityDot(isActive: true)
                            .accessibilityLabel("Running")
                    } else if let icon {
                        TabItemIconView(
                            icon: icon, ink: isActive ? surface.ink : Palette.textPrimary
                        )
                    }
                }
                .frame(width: TabItemIconView.pageSize, height: TabItemIconView.pageSize)
            }

            if isRenaming {
                // The field's ink is the tab's, not the environment's. A terminal tab carrying a
                // dark Ghostty ground was being renamed in the window's own label colour, which
                // over that fill is a line of black on black.
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(isActive ? surface.ink : Palette.textPrimary)
                    .focused($isRenameFocused)
                    .frame(minWidth: 0, idealWidth: Self.renameWidth, maxWidth: Self.renameWidth)
                    .onSubmit { onCommitRename(renameText) }
                    .onExitCommand(perform: onCancelRename)
            } else {
                Text(title)
                    .foregroundStyle(isActive ? surface.ink : Palette.textPrimary)
                    .lineLimit(1)
            }
        }
        .font(Typo.caption)
        .opacity(labelOpacity)
        .frame(height: Self.labelHeight)
        // Equal space on both sides centres the label independently of the leading close button.
        .padding(.horizontal, Self.closeSize + Metrics.spacingWide)
        .frame(minWidth: tabItemWidth ?? Self.minimumWidth, maxWidth: tabItemWidth ?? Self.maximumWidth)
        .frame(height: Self.tabHeight)
        // Decoration must not intercept the press that starts a tab drag. The closure also keeps
        // the fill inside the tab's bounds instead of extending into the unified toolbar inset.
        .background {
            background
                .padding(.horizontal, Metrics.spacingSmall / 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            closeButton.padding(.leading, Metrics.spacingSmall * 1.5)
        }
        .frame(height: Metrics.barHeight)
        .contentShape(Rectangle())
        // A single click selects and a double click renames, which is one gesture with two
        // meanings rather than a button, so it cannot be expressed as one.
        //
        // Simultaneous, not `.exclusively(before:)`. Exclusively made the select wait for the
        // double tap to FAIL, and a double tap only fails once the system's double click interval
        // has run out, so every click on a tab sat there for about 350ms before anything happened.
        // That was most of what switching tabs felt like. Recognised side by side, the select fires
        // on the first click and the rename on the second, which is also what the Finder does: the
        // second click of a rename lands on the row the first one already selected.
        //
        // What `simultaneous` also recognises alongside is a gesture defined by a SUBVIEW, and the
        // close cross is a `Button`, which is one. So a click on the cross ran `onClose()` and this
        // as well: the window switched to the tab it was in the middle of destroying and then
        // landed on whichever neighbour the store picked. The pointer has to be on the cross before
        // it can press it, so the hover the cross already tracks is what tells the two apart. Not a
        // `SpatialTapGesture` against the cross's frame, which would have to be measured and kept
        // in step with the layout; and not `.exclusively(before:)`, for the 350ms reason above.
        .simultaneousGesture(TapGesture().onEnded { if !isCloseHovered { onSelect() } })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if canRename { onStartRename() } })
        // The cross is only hit testable while the tab is hovered, so it cannot be pointed at once
        // this goes false. Cleared here as well rather than trusting the cross's own exit event to
        // arrive first, because a flag stuck true is a tab that stops selecting altogether.
        .onHover {
            isHovered = $0
            if !$0 { isCloseHovered = false }
        }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // Unnamed, so this is the DEFAULT action. Selecting is a tap gesture rather than a button
        // here, and a named action only appears in VoiceOver's actions rotor: the row said it was
        // a button and then did nothing when a reader pressed it.
        .accessibilityAction { onSelect() }
        .accessibilityActions { if canRename { Button("Rename", action: onStartRename) } }
        .contextMenu {
            if let onSplitRight, let onSplitDown {
                Button("Open in Split Right", systemImage: PaneSymbol.splitRight, action: onSplitRight)
                Button("Open in Split Down", systemImage: PaneSymbol.splitDown, action: onSplitDown)
                Divider()
            }
            if canRename {
                Button("Rename", systemImage: PaneSymbol.rename, action: onStartRename)
            }
            Button("Close", systemImage: PaneSymbol.closeTab, action: onClose)
                .disabled(!canClose)
        }
        .task(id: isRenaming) { await startEditing() }
        .transition(.opacity)
    }

    private var labelOpacity: Double {
        appearsActive || contrast == .increased ? 1 : 0.55
    }

    /// Keep enough of the pane's colour under the glass for custom terminal labels to stay legible.
    /// Inactive windows lose the glass finish but retain a visible selection.
    @ViewBuilder
    private var background: some View {
        if isActive {
            TabGlassBackground(shape: Capsule(), fill: surface.fill)
                .matchedGeometryEffect(id: Self.selectionID, in: namespace)
        } else if isHovered {
            Capsule().fill(Palette.hover)
        }
    }

    /// The label reserves this target's width even when the close button is invisible.
    ///
    /// Hover only, including on the selected tab. It used to sit on the selected tab at all times,
    /// on the argument that the tab you are looking at is the one you are most likely to close,
    /// and the cost of that was a cross parked in the middle of the strip whichever tab was on.
    /// Safari's strip carries no close control at rest on any tab, selected included, and the
    /// pointer is never more than a tab away on a Mac. Cmd+W and the context menu still close
    /// without a pointer at all.
    private var closeButton: some View {
        Button(action: onClose) {
            Label(closeTitle, systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                // A step under the label beside it, and at the label's own ink rather than a
                // paler one. Safari's cross is small against its titles and about as dark as
                // this: measured, the stroke reads mid grey on the hover fill, not a ghost. The
                // old cross had it the other way round, large enough to be the heaviest mark in
                // the strip while being too faint to look deliberate.
                .imageScale(.small)
                // Drawn in clear rather than faded with `.opacity`, which is the trick
                // `DiffLineView.commentButton` documents from a measurement: `.opacity(0)` on a
                // button or on its label took the element out of the accessibility hierarchy
                // entirely, so a hover-revealed control was one VoiceOver could never find. Clear
                // ink draws the same nothing and the element stays.
                .foregroundStyle(closeInk)
                .frame(width: Self.closeSize, height: Self.closeSize)
                .background {
                    if isVisible && isCloseHovered {
                        Circle()
                            .fill((isActive ? surface.ink : Palette.textPrimary)
                                .opacity(contrast == .increased ? 0.2 : 0.1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // What the tab's own tap gesture asks before it selects. See the gestures on the row.
        .onHoverChange { isCloseHovered = $0 }
        // Hit testing still follows the hover, and deliberately: this sits at a tab's leading
        // edge, and a close button that takes a click while invisible closes tabs somebody meant
        // to select.
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!canClose)
        .help(closeTitle)
    }

    private var closeInk: Color {
        guard isVisible else { return .clear }
        let ink = isCloseHovered
            ? (isActive ? surface.ink : Palette.textPrimary)
            : (isActive ? surface.inkMuted : Palette.textSecondary)
        return ink.opacity(labelOpacity)
    }

    private var isVisible: Bool {
        canClose && isHovered
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
