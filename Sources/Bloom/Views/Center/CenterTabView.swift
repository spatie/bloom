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
    /// The strip's namespace, so the selected tab's fill is one view that moves rather than one
    /// that is destroyed here and built again over there. Without it the highlight blinks from
    /// tab to tab, and a highlight that blinks is the single clearest tell that a tab strip was
    /// drawn rather than grown.
    var namespace: Namespace.ID

    /// A tab stops growing here so one long title cannot push every other tab out of the strip.
    private static let maximumWidth: CGFloat = 200
    /// Wide enough for the titles tabs actually get, and the same width whichever tab is being
    /// renamed, so the strip does not jump as the editor opens.
    private static let renameWidth: CGFloat = 140
    /// The row every tab centres in the strip. Fixed rather than intrinsic because a rename field
    /// is a point or two taller than a label, and a tab that grew as its editor opened put its
    /// text on a different line from the tabs beside it.
    private static let labelHeight: CGFloat = 20
    /// The top corners only, because the bottom ones are not there: the tab runs into the pane.
    /// Measured off Safari, whose selected tab is a full capsule floating inside its own inset
    /// track. A tab that reaches the content below it cannot be a capsule, and half a capsule is
    /// a dome, so this is the editor-tab radius the window already uses everywhere else.
    private static let cornerRadius = Metrics.corner
    /// One highlight for the whole strip, so `matchedGeometryEffect` has something to match on.
    private static let selectionID = "centerTab.selection"

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
                // One weight for every tab, selected or not. Safari's own strip sets both at the
                // same weight and the same colour and lets the shape carry the whole answer;
                // measured on a 26 window, a selected title and an unselected one are the same
                // ink. Bolding the selected one here was doing the shape's job badly: it moved
                // the text a point as the selection landed, and it left the tab reading as a
                // label that had been emphasised rather than as a tab that had come forward.
                //
                // The colour step stays. Bloom's strip is denser than Safari's and its tabs are
                // leading aligned rather than centred, so dropping to the secondary label is what
                // keeps an unselected run from competing with the pane it is sitting above.
                Text(title)
                    .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            closeButton
        }
        // One type size AND one weight for the whole row, set once above the branches, so
        // selection cannot change the metrics of anything. Everything a tab can hold is then on
        // the same line as everything a neighbouring tab holds, whatever each of them is showing,
        // and a tab that becomes selected does not reflow as it does so.
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
        //
        // Rounded at the top and square at the bottom for the same reason. Safari's selected tab
        // is the toolbar's own colour where the rest of its strip is a recess about five per cent
        // darker, and that difference, not the type, is the whole of what marks it; Bloom's fill
        // was already the right colour but was drawn as a plain rectangle, so in a light
        // appearance it came out the same white as the strip and marked nothing at all. Two
        // corners and a line down three sides give the fill an edge to be seen by.
        //
        // A closure rather than `.background(background)`. Handed a `Color`, that call resolves to
        // the `ShapeStyle` overload, whose `ignoresSafeAreaEdges` defaults to every edge, and the
        // strip sits directly under a unified toolbar. The selected tab's fill was therefore drawn
        // up through the whole toolbar inset, a block of it floating above the strip. The `View`
        // overload paints the tab's own bounds and nothing else.
        .background { background }
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
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onStartRename() })
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityAction(named: "Rename", onStartRename)
        .contextMenu {
            Button("Open in Split Right", systemImage: PaneSymbol.splitRight, action: onSplitRight)
            Button("Open in Split Down", systemImage: PaneSymbol.splitDown, action: onSplitDown)
            Divider()
            Button("Rename", systemImage: PaneSymbol.rename, action: onStartRename)
            Button("Close", systemImage: PaneSymbol.closeTab, action: onClose)
                .disabled(!canClose)
        }
        .task(id: isRenaming) { await startEditing() }
    }

    /// Nothing at rest on an unselected tab, which is why this is a builder rather than a colour.
    /// A `.clear` fill is still a view, and a view is still a thing `matchedGeometryEffect` can
    /// try to match, so the unselected case has to be absent rather than transparent.
    ///
    /// The hover fill wears the same top corners as the selected one so the two are obviously the
    /// same shape, but it moves the other way: over the strip's recess, selection lightens towards
    /// the pane in a light appearance and darkens towards it in a dark one, while hover always
    /// goes the opposite way. That is what stops a hovered tab from being read as a selected one.
    @ViewBuilder
    private var background: some View {
        if isActive {
            shape
                .fill(Palette.surface)
                .overlay {
                    CenterTabOutline(radius: Self.cornerRadius)
                        .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
                }
                .matchedGeometryEffect(id: Self.selectionID, in: namespace)
        } else if isHovered {
            shape.fill(Palette.hover)
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Self.cornerRadius,
            topTrailingRadius: Self.cornerRadius,
            style: .circular
        )
    }

    /// Kept in the layout even when it is invisible, so no label moves when the pointer enters.
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
                .foregroundStyle(Palette.textSecondary)
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
