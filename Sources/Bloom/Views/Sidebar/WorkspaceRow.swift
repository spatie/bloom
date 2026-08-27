import SwiftUI
import BloomCore

/// One workspace in the sidebar.
///
/// This exists as its own type because the leading glyph carries more weight than anything else
/// in the window: with a dozen agents running in parallel, the glyph is the only thing that says,
/// without a click, which of them is working, which needs reading and which fell over. Everything
/// else on the row is secondary and is allowed to truncate.
///
/// What the mark distinguishes is decided by `WorkspaceStatus`, not here, and how it is drawn by
/// `WorkspaceStatusGlyph`, which the legend shares so the two cannot describe different marks. The
/// verdict spans both halves of a workspace's life, the local one (setting up, running, unread,
/// changed) and GitHub's (draft, checks, merged), because a column that shows only the local half
/// cannot answer the question the user actually has, which is which of these is finished.
///
/// The row is a `Label`, not an `HStack` with a glyph in front of the name. That is what keeps the
/// mark and the name on the icon and text columns the list itself defines, so the rows of one
/// project line up with each other and with the notice that stands in for them when a project is
/// empty, instead of the three columns the hand-built stack produced.
///
/// The whole row is then indented one chevron gutter by `SidebarWorkspaceRow`, which is what
/// puts it under the project it belongs to rather than under Home and Search. See
/// `SidebarMetrics.rowIndent`.
///
/// The row draws no background of its own. It lives in a `List` with `.listStyle(.sidebar)`, and
/// that list already draws AppKit selection: the accent colour while the list has the keyboard, a
/// quiet grey when it does not. Painting a second highlight underneath was what produced the solid
/// dark bar the owner saw.
///
/// Text uses the hierarchical styles rather than fixed label colours for the same reason: inside
/// a selected row the list inverts `.primary` and `.secondary` for us, and a pinned
/// `NSColor.labelColor` would stay dark on the accent fill.
struct WorkspaceRow: View {
    var workspace: Workspace
    /// Whether an agent is mid turn in this workspace. Passed in rather than read here, so the row
    /// stays a pure function of its inputs.
    var isRunning: Bool
    var isAwaitingPermission = false
    /// The id of the row being renamed in place, shared across the whole list so only one field
    /// can ever be open.
    @Binding var renaming: WorkspaceID?
    /// Raised to `SidebarWorkspaceRow`, which owns both the confirmation and the call into the
    /// model, so this button and the row's context menu cannot end up on different paths.
    var onArchive: (Workspace) -> Void

    @Environment(AppModel.self) private var app

    /// How many of this turn's subagents failed, whichever of them still have rows of their own.
    private var subagentFailures: Int { app.subagentFailures(of: workspace.id) }
    /// Whether this row is the one the list is painting with the accent colour.
    ///
    /// This is the list's own answer, not one derived from the window's active state. AppKit fills
    /// a selected row with the accent only while the list itself holds the keyboard, so a row that
    /// inverted whenever the window was merely key drew white counts on the grey unfocused bar
    /// every time focus was in the composer or a terminal.
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the pointer is on this row. Per row rather than an id shared across the list, so
    /// crossing the pane lights one row at a time.
    @State private var isHovered = false
    @State private var draft = ""
    /// Whether this rename has already been finished, so the four ways of leaving the field cannot
    /// write the name twice. Reset when the field opens. See `end(_:)`.
    @State private var hasEnded = false
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { renaming == workspace.id }

    private var isEmphasized: Bool { backgroundProminence == .increased }

    var body: some View {
        // Bound once. `status` was resolved three times a pass and the pull request dictionary read
        // five, because the sentence reaches both and is asked for twice, by the tooltip and by
        // VoiceOver, which get the same words on purpose. GitHub's answer is read straight from the
        // shared store rather than passed in, because the sidebar's row builder cannot reach it.
        let pullRequest = WorkspacePullRequests.shared.pullRequest(for: workspace.id)
        let status = WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: isRunning,
            pullRequest: pullRequest,
            isAwaitingPermission: isAwaitingPermission
        )
        let statusDescription = status.summary(pullRequest: pullRequest)

        Label {
            HStack(spacing: Metrics.spacing) {
                if isRenaming {
                    TextField("Workspace name", text: $draft)
                        .textFieldStyle(.plain)
                        // Said rather than inherited, and that is the whole fix. A selected row
                        // hands its contents `Palette.textInverted`, which is white, because the
                        // row behind them is the accent fill. An editing field is not on that
                        // fill: it paints its own light editing background while it has focus, so
                        // the name being typed came out white on white and the row looked empty.
                        // The field's own ink is `labelColor`, which is right against that
                        // background in both appearances and owes nothing to what is behind it.
                        .foregroundStyle(Palette.textPrimary)
                        .focused($fieldFocused)
                        .onSubmit { end(.submitted) }
                        .onExitCommand { end(.escaped) }
                        // Clicking away commits, which is what Finder, Xcode and Mail do and what
                        // this field did not: it stayed open on the row holding uncommitted text
                        // for as long as the window was left alone. Guarded on having had the
                        // focus, so the false this starts at is not read as having lost it.
                        .onChange(of: fieldFocused) { had, has in
                            guard had, !has else { return }
                            end(.focusLost)
                        }
                        .task {
                            draft = workspace.name
                            hasEnded = false
                            // A beat, so the field exists before focus moves to it.
                            try? await Task.sleep(for: .milliseconds(30))
                            fieldFocused = true
                        }
                } else {
                    WorkspaceNameText(workspace, isUnread: workspace.unread)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Right after the name, which is where Finder puts a tag on a file. Drawn only
                    // when there is one, so an unmarked pane looks exactly as it did. It carries
                    // its own accessibility label here, unlike on Home, because this row exposes
                    // its children rather than merging them into one sentence.
                    WorkspaceColourDot(
                        hex: workspace.colour,
                        accessibilityName: workspace.colourDescription
                    )

                    Spacer(minLength: Metrics.spacingSmall)

                    if workspace.pinned {
                        Image(systemName: "pin.fill")
                            .font(Typo.micro)
                            // The palette's rung rather than AppKit's third, which `textTertiary`
                            // was retuned away from: the system's is 1.9 to 1 and means a disabled
                            // control. Home draws the same pin and always did it this way.
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityLabel("Pinned")
                    }

                    // What is left on the workspace row when a subagent's own row goes.
                    //
                    // A tick leaves nothing: the workspace carrying on already says the work
                    // landed. A cross leaves this, because the workspace row is the one that
                    // persists and a failure nobody saw is the whole risk in removing rows at
                    // all. It also carries the overflow past `SubagentRetention.failureLimit`,
                    // which is what makes capping the crosses safe: three rows and a five here
                    // never disagree about how bad it was. See `SubagentRetention`.
                    if subagentFailures > 0 {
                        Label("\(subagentFailures)", systemImage: "xmark")
                            .font(Typo.micro)
                            .monospacedDigit()
                            .labelStyle(SubagentFailureLabelStyle())
                            .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.negative)
                            .opacity(isHovered ? 0 : 1)
                            .accessibilityLabel(subagentFailures == 1
                                ? "1 subagent failed this turn"
                                : "\(subagentFailures) subagents failed this turn")
                    }

                    // In the layout, not overlaid, so a name shares the row with real counts
                    // rather than running underneath them. Hidden while the pointer is here,
                    // which is when the controls draw in their place.
                    if workspace.hasDiff {
                        DiffStatLabel(
                            additions: workspace.additions,
                            deletions: workspace.deletions,
                            compact: true
                        )
                        .opacity(isHovered ? 0 : 1)
                    }
                }
            }
            .mask { trailingYield }
            .overlay(alignment: .trailing) { hoverControls }
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
        } icon: {
            WorkspaceStatusGlyph(status: status, isOnSelection: isEmphasized)
        }
        // See `SidebarRowLabelStyle`. The mark has to be laid out by this row rather than by the
        // list, or it does not travel with the row when a project folds.
        .labelStyle(SidebarRowLabelStyle())
        // The glyph is the row's whole state in one mark, so VoiceOver has to be told what it
        // means rather than being handed an unlabelled image. It sits on the row: the icon of a
        // `Label` is not a hit target of its own.
        //
        // **No `.help` here, and that is a removal rather than an omission.** It carried the same
        // sentence as `accessibilityValue`, and the hover card says all of it and more: the
        // branch, the diff, the pull request, the checks and the age. So resting on a row raised
        // a system tooltip and our own card at once, a few points apart, one repeating a line of
        // the other. The card is the better of the two and it is the one that stays; a reader who
        // cannot see it still has the accessibility value, which is what that line was really for.
        .accessibilityValue(statusDescription)
        .contentShape(Rectangle())
        // Command-Backspace is delete-to-start-of-line in a text box, and the menu bar had it
        // for Archive Workspace. See `FocusedValues.isTypingProse`.
        .focusedValue(\.isTypingProse, fieldFocused)
        .onHover { isHovered = $0 }
        // Only rows that exist ask GitHub anything, and the id carries the branch and whether
        // there is any work at all, because both change what is worth asking about.
        .task(id: PullRequestQuestion(
            workspace: workspace.id, branch: workspace.branch, hasDiff: workspace.hasDiff
        )) {
            await WorkspacePullRequests.shared.track(workspace)
        }
        // The list inverts the row's text for us, but a label that carries its own colour, such as
        // the green plus count, has to be told. This is the same signal the inspector's lists send.
        .environment(\.isOnEmphasizedSelection, isEmphasized)
        // On the ROW rather than on the field, because this is the ending the field is not around
        // to see: `SidebarView` closes it whenever the selection moves, and what was typed used to
        // go with it. The row is still in the list when that happens, so this fires and the name is
        // written. See `InPlaceRename`.
        .onChange(of: isRenaming) { was, now in
            guard was, !now else { return }
            end(.dismissed)
        }
    }

    // MARK: - Trailing

    /// Whether the two hover controls are being shown. Never while renaming: the field owns the
    /// whole row, and controls drawn over its trailing edge would sit on the text being typed.
    private var controlsShown: Bool { isHovered && !isRenaming }

    /// The width the controls cover when they are shown: the two buttons, side by side.
    private static let controlsWidth = SidebarMetrics.rowButton * 2

    /// How far the content underneath fades before the controls begin, so a name that reaches
    /// them is cut with a fade rather than a cliff.
    private static let controlsFade: CGFloat = 12

    /// The row's two controls, drawn over the trailing edge while the pointer is on the row.
    ///
    /// Conductor swaps the counts for the controls under the pointer, the owner asked for the
    /// same, and a swap is the right shape here because the two are never both worth reading: the
    /// counts say how much changed and the controls are what you reach for when you have finished
    /// reading them.
    ///
    /// **An overlay, not a layout slot, and the difference is forty points of every name.** The
    /// first build kept the controls in the row's layout at every moment, at opacity nought
    /// inside a `ZStack` with the counts, so that nothing could move when the pointer landed. It
    /// worked, and it charged every row the width of both buttons whether anything would ever
    /// draw there or not: the owner measured names in his own sidebar truncating some seventy
    /// points short of the row's edge and asked for the room back. So the guarantee is now kept
    /// the other way round. The controls take no layout space at all, the name runs to the row's
    /// edge, and when the pointer arrives the trailing region YIELDS instead of the name
    /// reflowing: `trailingYield` fades out whatever the controls would land on and the controls
    /// draw on the cleared ground. Nothing moves in either direction, because nothing's measured
    /// size ever changes.
    ///
    /// What yields is whatever happens to live in the last fifty points: usually the counts,
    /// sometimes the pin or the tail of a long name. The counts always yielded; the pin and the
    /// tail are new to it, which is a real cost, and it is the right side of the trade because
    /// hovering is the reading state of one row under the pointer while rest is the reading state
    /// of the whole pane. Everything comes back the moment the pointer leaves.
    ///
    /// The reveal follows the project header's GEAR rather than its `+`: from nothing, not lit
    /// from a resting state. The `+` is present at rest because creating is the thing anyone does
    /// often enough to go looking for. Archiving is the opposite, and a column of archive boxes
    /// down a pane whose job is to name the work would read as an invitation. The menu is the same
    /// argument: a column of ellipses says nothing about any of the rows it is drawn on.
    ///
    /// The menu leads and the archive follows, so the archive keeps the row's trailing edge it
    /// has always had. Moving a destructive control that people have already learned the position
    /// of, so that a habitual click lands on a menu instead, is a worse trade than either order is
    /// worth.
    private var hoverControls: some View {
        HStack(spacing: 0) {
            moreMenu
            archiveButton
        }
        .opacity(controlsShown ? 1 : 0)
        // An invisible control still takes clicks, which over the trailing edge of a row would
        // be the worst possible bug in a destructive one. The pointer has to be on the row for
        // either to be drawn at all, so this costs nothing real.
        .allowsHitTesting(controlsShown)
    }

    /// The mask that clears the ground under the controls while they are shown.
    ///
    /// A full rectangle at rest, so it changes nothing, with an eraser over the trailing edge
    /// that fades in with the controls: opaque behind the buttons themselves, thinning to nothing
    /// over `controlsFade` more points. `destinationOut` inside a `compositingGroup` is what
    /// punches alpha OUT of a mask that is otherwise solid; the obvious alternative, two mask
    /// shapes switched by the hover, cannot animate between its states.
    ///
    /// A mask on the content rather than a plate behind the controls, because the row does not
    /// know what it is sitting on: the accent fill when selected with the keyboard, the quiet
    /// grey when selected without it, bare sidebar material otherwise. Erasing the content shows
    /// the true ground, whichever that is, so the buttons stand on the same fill as the rest of
    /// the row.
    private var trailingYield: some View {
        Rectangle()
            .overlay(alignment: .trailing) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(
                            color: .black,
                            location: Self.controlsFade / (Self.controlsFade + Self.controlsWidth)
                        ),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: Self.controlsFade + Self.controlsWidth)
                .blendMode(.destinationOut)
                .opacity(controlsShown ? 1 : 0)
            }
            .compositingGroup()
    }

    /// Everything you can do to this workspace, one press away instead of one right click away.
    ///
    /// It draws `WorkspaceMenuItems`, which is the identical view `SidebarWorkspaceRow` hands to
    /// `.contextMenu` on this same row, so the button and the right click cannot come up with
    /// different menus. That is not tidiness: two menus on one row that differ by an item is a
    /// worse bug than the button being in the wrong place, and this menu already exists in one
    /// copy precisely because the sidebar's and Home's had drifted apart.
    ///
    /// It came from the title bar, where it was three items (Open in Editor, Reveal in Finder,
    /// Copy Branch Name) that this row's menu already carried in full. So nothing was merged and
    /// nothing was lost: the affordance moved onto the thing it acts on, and the three items are
    /// still in the Workspace menu with their shortcuts for anyone with no pointer on this row.
    ///
    /// **Archive is in here as well as beside it, and the two ask differently on purpose.** The
    /// button next to this one confirms every time because it appears unbidden under the pointer
    /// a few points from the row you meant to click. Choosing Archive out of an open menu is not
    /// that: you opened the menu and read the item, exactly as with the right click, so it takes
    /// the conditional path that stays quiet when there is nothing to lose. See
    /// `SidebarWorkspaceRow.confirmRowArchive`.
    private var moreMenu: some View {
        Menu {
            WorkspaceMenuItems(workspace: workspace) { renaming = $0 }
        } label: {
            // Still the CIRCLED ellipsis, which is not what the colour complaint looked like it
            // was asking for. A bare `ellipsis` was the obvious partner for `archivebox`, on the
            // grounds that a plain outline should stand beside a plain outline, and it was drawn
            // and rejected on the picture: the archive is an enclosing glyph, so three loose dots
            // beside it read as a control and a smudge rather than as a pair. The ink says the
            // same. Counted over the two boxes on a window capture, the ring and the archive come
            // to 176 and 215 inked pixels; the bare dots come to 48, under a quarter of their
            // neighbour. The circle is the one that matches the weight it has to live next to.
            Label("More for \(workspace.name)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                // The archive button's box, so the two stand at one size and the press target is
                // the box rather than the glyph. `fixedSize` below is what stops the menu style
                // widening it again.
                .frame(width: SidebarMetrics.rowButton, height: SidebarMetrics.rowButton)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        // Not `.borderlessButton`, and this pair of lines is the whole of "it's strange that we
        // have archive and circle dots in another color".
        //
        // `.borderlessButton` draws its label in an ink of its own and ignores the colour it is
        // given, wherever that colour is stated. Measured off a window capture of this row, with
        // both controls carrying the identical `foregroundStyle`: the archive's darkest pixel was
        // #7A7B7C, which is `secondaryLabelColor` composited on the sidebar, and the menu's was
        // #A5A8A9 with a mean of #B2B5B6, a tertiary weight nothing asked for. Moving the colour
        // onto the label's own leaf changed neither number by a single count, which is what rules
        // out the glyph and rules out the call site: the style is simply not passing it down.
        //
        // `.button` does pass it down, because it defers to the BUTTON style, and `.plain` is the
        // one the archive beside it already uses. Re-measured the same way, the ellipsis's dots
        // came out at #7A7B7C, equal to the archive's darkest pixel to the count.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.textSecondary)
        .help("More for this workspace")
    }

    private var archiveButton: some View {
        Button {
            onArchive(workspace)
        } label: {
            Image(systemName: "archivebox")
                .font(Typo.caption)
                .frame(width: SidebarMetrics.rowButton, height: SidebarMetrics.rowButton)
                // The padding is the click target and it is inside the label, because a button's
                // hit area is its label. A `contentShape` outside the button widens nothing.
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.textSecondary)
        // One notation for a shortcut in a tooltip, everywhere: the glyphs, in brackets, after
        // the sentence. The app had three, and this row was the one that wrote two spaces and
        // no brackets. The other two were `SidebarProjectsHeader`, which already reads this
        // way, and `ComposerStopButton`, which spelled the keys out in words.
        .help("Archive workspace (⌘⌫)")
        .accessibilityLabel("Archive \(workspace.name)")
    }

    // MARK: - Renaming

    /// One door out of the field, for all four ways of leaving it.
    ///
    /// `hasEnded` is what stops the name being written twice. Ending the rename clears `renaming`,
    /// which both removes the field (so the focus change fires) and flips `isRenaming` (so the
    /// row's own watcher fires), and the write is asynchronous, so the second caller would still
    /// see the old name and ask for the same rename again.
    private func end(_ ending: InPlaceRename.Ending) {
        guard !hasEnded else { return }
        hasEnded = true
        // Only if the field is still this row's. Starting a rename on another row is what ends
        // this one, and clearing the shared id unconditionally would close the field that had just
        // been opened over there.
        if renaming == workspace.id { renaming = nil }
        guard case .commit(let name) = InPlaceRename.outcome(
            ending, draft: draft, current: workspace.name
        ) else { return }
        Task { await app.rename(workspace, to: name) }
    }
}

/// What is worth asking GitHub about again, as a value rather than as the interpolated string this
/// used to be: that string was built on every pass of every row and never read, because a `.task`
/// id is only ever compared.
private struct PullRequestQuestion: Hashable, Sendable {
    var workspace: WorkspaceID
    var branch: String
    var hasDiff: Bool
}

/// The cross and its count, set tight so the pair reads as one mark rather than as an icon beside
/// a number. The same shape the subagent rows use, at the same size the diff stat beside it uses.
private struct SubagentFailureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.spacingTight) {
            configuration.icon
            configuration.title
        }
    }
}
