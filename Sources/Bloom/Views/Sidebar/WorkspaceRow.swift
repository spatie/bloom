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
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { renaming == workspace.id }

    private var isEmphasized: Bool { backgroundProminence == .increased }

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacing) {
                if isRenaming {
                    TextField("Workspace name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { commit() }
                        .onExitCommand { renaming = nil }
                        .task {
                            draft = workspace.name
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
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                    trailingSlot
                }
            }
        } icon: {
            WorkspaceStatusGlyph(status: status, isOnSelection: isEmphasized)
        }
        // See `SidebarRowLabelStyle`. The mark has to be laid out by this row rather than by the
        // list, or it does not travel with the row when a project folds.
        .labelStyle(SidebarRowLabelStyle())
        // The glyph is the row's whole state in one mark, so VoiceOver has to be told what it
        // means rather than being handed an unlabelled image, and a pointer resting on it gets the
        // same sentence. Both sit on the row: the icon of a `Label` is not a hit target of its own.
        .accessibilityValue(statusDescription)
        .help(statusDescription)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Only rows that exist ask GitHub anything, and the id carries the branch and whether
        // there is any work at all, because both change what is worth asking about.
        .task(id: "\(workspace.id)|\(workspace.branch)|\(workspace.hasDiff)") {
            await WorkspacePullRequests.shared.track(workspace)
        }
        // The list inverts the row's text for us, but a label that carries its own colour, such as
        // the green plus count, has to be told. This is the same signal the inspector's lists send.
        .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    // MARK: - Trailing

    /// What the trailing edge of the row shows: the diff counts at rest, the row's two controls
    /// under the pointer.
    ///
    /// Conductor swaps the two, the owner asked for the same, and a swap is the right shape here
    /// because the two are never both worth reading: the counts say how much changed and the
    /// controls are what you reach for when you have finished reading them.
    ///
    /// **The counts are what yields, and they are the only thing that does.** Everything else on
    /// the row is content that has to survive the pointer arriving: the status mark says which
    /// agent needs you, the name says which piece of work it is, the colour dot and the pin were
    /// put there by hand. The counts are the one thing on the row that is still true a second
    /// later when the pointer has gone, so covering them for as long as the pointer is here costs
    /// nothing that cannot be had back by moving it away.
    ///
    /// Stacked rather than switched, and both halves stay in the hierarchy at every moment with
    /// only their opacity moving. That is what stops the name reflowing as the pointer crosses the
    /// row: the slot is as wide as the wider of the two whether the pointer is there or not, so a
    /// row with no counts at all reserves exactly the same space and its controls appear in
    /// exactly the same place. It also keeps one view identity on each side of the hover rather
    /// than building and tearing one down. The slot grew by one button's width when the menu
    /// arrived, and it grew for EVERY row at rest as well as under the pointer, which is the whole
    /// point: a name is truncated a little sooner, and nothing moves when the pointer lands.
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
    /// worth; the new control goes in space that held nothing.
    @ViewBuilder
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            if workspace.hasDiff {
                DiffStatLabel(
                    additions: workspace.additions,
                    deletions: workspace.deletions,
                    compact: true
                )
                .opacity(isHovered ? 0 : 1)
            }

            HStack(spacing: 0) {
                moreMenu
                archiveButton
            }
            .opacity(isHovered ? 1 : 0)
            // An invisible control still takes clicks, which at the trailing edge of a row would
            // be the worst possible bug in a destructive one. The pointer has to be on the row for
            // either to be drawn at all, so this costs nothing real.
            .allowsHitTesting(isHovered)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
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
            Label("More for \(workspace.name)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(Typo.caption)
                // Sized inside the label, the way the archive button beside it is, so the two
                // stand in boxes of one size and the press target is the box rather than the
                // glyph. `fixedSize` below is what stops the menu style widening it again.
                .frame(width: SidebarMetrics.rowButton, height: SidebarMetrics.rowButton)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        .menuStyle(.borderlessButton)
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
        // The shortcut is named the way Conductor names its own, with ours rather than theirs.
        .help("Archive workspace  ⌘⌫")
        .accessibilityLabel("Archive \(workspace.name)")
    }

    // MARK: - Status

    /// GitHub's answer for this branch, if anything has asked yet. Read straight from the shared
    /// store rather than passed in, because the sidebar's row builder has no way to reach it.
    private var pullRequest: PullRequest? {
        WorkspacePullRequests.shared.pullRequest(for: workspace.id)
    }

    private var status: WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: isRunning,
            pullRequest: pullRequest,
            isAwaitingPermission: isAwaitingPermission
        )
    }

    /// What the mark means, in one sentence, for the tooltip and for VoiceOver. Both get the same
    /// words on purpose: a sighted user hovering and a VoiceOver user landing on the row are
    /// asking the identical question.
    private var statusDescription: String {
        status.summary(pullRequest: pullRequest)
    }

    // MARK: - Renaming

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != workspace.name else { return }
        Task { await app.rename(workspace, to: name) }
    }
}
