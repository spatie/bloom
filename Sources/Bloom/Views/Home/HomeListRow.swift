import SwiftUI
import BloomCore

/// One workspace on Home, on one line.
///
/// The order across the row is the order the questions are asked in. Something at the very leading
/// edge says "look here"; the project mark says whose work this is; the name says which piece of
/// it; the mark, the counts and the age on the trailing edge say how it went and how long ago.
///
/// **Why the project mark leads and the status mark does not.** In the sidebar the workspace sits
/// under its project's heading, so the leading slot is free for the status glyph and that is what
/// fills it. Home is flat and crosses every project, so the one thing that cannot be worked out
/// from anywhere else on the row is which project it belongs to. The status mark keeps its shape
/// and its colour, it simply moves to the trailing cluster where the rest of the outcome is.
///
/// **The rail.** Conductor puts a short coloured bar at the leading edge of some rows. Ours is the
/// same idea with a rule behind it: it appears only for a workspace that is being worked on or is
/// waiting for a person (`WorkspaceStatus.homeLane`), and it is drawn in exactly the tint
/// `WorkspaceStatusGlyph` gives that state, so it is the sidebar's colour language projected onto
/// the edge of the row rather than a second one. Nothing is carried by the rail alone: the same
/// state is in the glyph's shape, in the row's accessibility label and, for an unread turn, in the
/// weight of the name. That weight is `WorkspaceNameText`'s to pick rather than this row's, so the
/// same workspace cannot be one weight here and another in the sidebar.
///
/// **The row draws no selection of its own and inverts nothing.** It used to take `isSelected` and
/// `isListFocused` and flip every colour on the row to white when the list held the keyboard,
/// because that is what `.listStyle(.inset)` paints underneath: a full bleed bar of the system
/// accent. That made Home's keyboard selection a third selection treatment, next to the sidebar's
/// and the inspector's soft inset grey, and by a distance the loudest thing in the window. The
/// fill is now `HomeRowBackground`, handed to the list as a `listRowBackground`, which covers
/// AppKit's own and is the same quiet grey the rest of the app selects with. Nothing on the row
/// has to know it is selected any more, which is why every `isEmphasized` branch is gone.
struct HomeListRow: View {
    var row: HomeRow
    var isRunning: Bool
    var isAwaitingPermission = false
    var now: Date
    /// Whether the row is the one being renamed in place. The list owns the id, so only one field
    /// can ever be open.
    var isRenaming: Bool
    /// Raised to the list, which is also where the rename is committed from.
    var onCommitRename: (String) -> Void
    var onCancelRename: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var workspace: Workspace { row.workspace }

    /// A hairline is too thin to read as a colour and a full chip is a second badge. Three points
    /// is what a coloured edge marker is on a Mac. Local rather than in `Metrics` because nothing
    /// else in the window has one yet; a candidate for promotion if a second list grows one.
    private static let railWidth: CGFloat = 3

    /// Wide enough for "10mo" so the ages line up as a column rather than ragging against the
    /// window edge.
    private static let ageWidth: CGFloat = 34

    /// Wide enough for the widest pair the abbreviation can produce, `+2.7k -1.2k`.
    ///
    /// Fixed rather than sized to its content, and that is what makes the trailing side a set of
    /// columns instead of three ragged stacks. With the counts free to be any width, the status
    /// mark to their left landed at a different x on every row, and a column of marks that does
    /// not line up cannot be read down.
    private static let diffWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            rail

            RepoIcon(repo: row.repo)

            if isRenaming {
                TextField("Workspace name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { onCommitRename(draft) }
                    .onExitCommand(perform: onCancelRename)
                    .task {
                        draft = workspace.name
                        // A beat, so the field exists before focus moves to it.
                        try? await Task.sleep(for: .milliseconds(30))
                        fieldFocused = true
                    }
            } else {
                WorkspaceNameText(workspace, isUnread: isUnread)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Right after the name, the same place the sidebar puts it, so one workspace is
                // marked in one way in both lists. No accessibility label of its own: this row is
                // merged into a single element below, which would swallow it, so the colour is
                // said in `accessibilityLabel` instead.
                //
                // Nothing special for the archived case. The whole row is drained by `grayscale`
                // a few lines down, which takes the dot with it, and that is the right answer: an
                // archived workspace cannot be given a colour or have one taken off.
                WorkspaceColourDot(hex: workspace.colour)

                if workspace.pinned {
                    Image(systemName: "pin.fill")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                }
            }

            Spacer(minLength: Metrics.spacingWide)

            trailing
        }
        // Said rather than inherited, and this is what stops the list from bleaching the row.
        //
        // `List` still knows which row is selected, because the arrow keys need it to, and AppKit
        // still inverts a selected row's text to white for the accent fill it thinks it drew. The
        // fill is covered by `HomeRowBackground`; the inversion is not, and without this the
        // selected row's name went white on a pale grey plate and all but disappeared. Everything
        // on the row that carries a colour of its own (the rail, the glyph, the counts) already
        // states it; this is for everything that does not.
        .foregroundStyle(Palette.textPrimary)
        // Greyed as a whole rather than colour by colour. An archived workspace still has a
        // project mark, a diff and an age, and picking a quieter variant of each of them would be
        // four decisions where the row only makes one: this is over.
        //
        // Two lines because "grey" is two things. The hue goes first, which is what the diff
        // counts used to ask for on their own: a saturated green and a saturated red at 60 per
        // cent are still a saturated green and a saturated red, and they were the loudest thing
        // left on the row that is meant to be the quietest in the list. Drained, they dim with
        // everything else, and so does the project mark, which is the other thing on the row with
        // a colour of its own and no reason to keep it once the work is over.
        //
        // Then the whole thing steps back, and one step further than it used to. Measured off a
        // window capture in light appearance, the name on an archived row came out #838383 at
        // 0.55, which is 3.8 to 1 against the pane; at 0.6 it is #7D7D7D and 4.1 to 1, a shade
        // above where macOS's own `secondaryLabelColor` sits at 3.9. That is the right rung: it
        // is what the system uses for text that recedes and still has to be read. Receding is the
        // point, unreadable is not, and with the hue gone the row has one fewer signal carrying
        // the state, so the ink can afford it. These rows are no longer an occasional visit
        // either; they are part of the list Home opens on.
        .grayscale(row.isArchived ? 1 : 0)
        .opacity(row.isArchived ? 0.6 : 1)
        .frame(minHeight: Metrics.rowHeight)
        // The whole row, including the gap the name does not fill, is the click target. Without
        // it only the text is, and a list where half of each row ignores the pointer feels broken
        // long before anyone works out why.
        .contentShape(Rectangle())
        // Merged into one sentence. Left as separate elements, VoiceOver reads a name, a repeated
        // project name, two bare numbers and "1d", in that order, which says nothing. Not while
        // renaming, though: the merge swallowed the rename field, so Rename from this row's own
        // context menu handed a VoiceOver user a field they could not reach.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityInputLabels([workspace.name])
        .accessibilityAddTraits(isRenaming ? [] : .isButton)
        .help(help)
    }

    // MARK: - Parts

    /// Always occupies its width, so every name in the list starts on the same vertical line
    /// whether or not its row is marked.
    private var rail: some View {
        RoundedRectangle(cornerRadius: Self.railWidth / 2, style: .continuous)
            .fill(railTint)
            .frame(width: Self.railWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, Metrics.spacingTight)
            .opacity(showsRail ? 1 : 0)
            .accessibilityHidden(true)
    }

    /// The outcome, what it came to, and when. In that order because the glyph is a shape read at
    /// a glance, the counts are numbers read on purpose, and the age is the column the eye runs
    /// down when it is looking for the boundary between two date headings.
    ///
    /// **No hover controls here, and the sidebar's row has two.** That is a difference between the
    /// two lists rather than an omission. This side is three columns of fixed width whose entire
    /// purpose is that a mark, a count and an age line up down the list; a control revealed in one
    /// of them would cover a column the eye is running down, and one reserved beside them would
    /// add a fourth for something that is empty on every row at rest. The row is also a single
    /// merged accessibility element, which is what makes it readable by ear, and a merged element
    /// has nowhere to put a button. Home has never had the archive button either, for the same
    /// reason, and the right click gives this row the identical `WorkspaceMenuItems` the sidebar's
    /// button opens.
    private var trailing: some View {
        HStack(spacing: Metrics.spacingWide) {
            if row.isArchived {
                // An archived worktree is gone, so "checks passed" or "has changes" would be a
                // report about something that no longer exists.
                Image(systemName: "archivebox")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: Metrics.glyph, height: Metrics.glyph)
                    .accessibilityHidden(true)
            } else {
                WorkspaceStatusGlyph(status: status, isOnSelection: false)
                    .accessibilityHidden(true)
            }

            // A real container rather than a `Group` around the condition. A frame on a `Group`
            // is applied to each of its children, so an empty one keeps no width at all and the
            // status mark to its left slid two centimetres right on every row without a diff.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // No archived case of its own any more. These two counts used to drain their own
                // hue, because they were the only thing on the row loud enough to need it; the
                // row now drains itself, and a second copy of that decision here would be the
                // one place the treatment could drift from the rest of the line.
                if workspace.hasDiff {
                    DiffStatLabel(
                        additions: workspace.additions,
                        deletions: workspace.deletions,
                        compact: true
                    )
                }
            }
            .frame(width: Self.diffWidth)

            Text(HomeAge.short(for: workspace.lastActivityAt, now: now))
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Self.ageWidth, alignment: .trailing)
        }
    }

    // MARK: - State

    /// Read from the shared cache, never requested. The sidebar's rows are what keep it warm; a
    /// second poller on Home would double the `gh` subprocesses for the same answer, and with
    /// forty rows on screen that is forty processes for a screen nobody has clicked into yet.
    private var pullRequest: PullRequest? {
        WorkspacePullRequests.shared.pullRequest(for: workspace.id)
    }

    /// Whether the name is set in the unread weight. Archived wins over unread, deliberately.
    ///
    /// The two do meet: archiving does not clear the flag, so a workspace whose agent finished
    /// while nobody was looking and was archived that evening arrives here both unread and over.
    /// Three things settle it the same way. The flag would be unclearable: reading an archived
    /// workspace opens `ArchivedWorkspaceView`, which deliberately marks nothing read because
    /// there is nothing to go back to, so the row would be heavy forever with no way to answer
    /// it. It would be the only unread mark in the app that no other part of the app agrees
    /// with: `DockBadge` counts `AppModel.workspaces`, which holds active workspaces only, and
    /// the sidebar never lists an archived one at all, so Home would be shouting about a
    /// workspace the badge and the sidebar both consider settled. And the two states say opposite
    /// things: unread means "this wants you", archived means "this is done with you". A row
    /// cannot be both, and the one the user acted on last is the one that is true.
    private var isUnread: Bool {
        !row.isArchived && workspace.unread
    }

    private var status: WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: isRunning,
            pullRequest: pullRequest,
            isAwaitingPermission: isAwaitingPermission
        )
    }

    /// Resting states get no rail. A rail on every row is a stripe down the edge of the list, and
    /// the point of it is that only a few rows have one.
    private var showsRail: Bool {
        !row.isArchived && status.homeLane != .resting
    }

    private var railTint: AnyShapeStyle {
        WorkspaceStatusGlyph.tint(for: status)
    }

    // MARK: - Words

    private var statusDescription: String {
        row.isArchived ? "Archived" : status.summary(pullRequest: pullRequest)
    }

    private var help: String {
        var text = statusDescription
        if let repo = row.repo { text += " in \(repo.name)" }
        return text
    }

    /// Everything the row shows, as one sentence, with the state in it rather than only the name.
    /// A list read by ear is unusable if every row announces "some-branch-name, 267, 109".
    private var accessibilityLabel: String {
        var parts = [workspace.name]
        if let repo = row.repo { parts.append("in \(repo.name)") }
        parts.append(statusDescription)
        if let colour = workspace.colourDescription { parts.append("colour \(colour)") }
        if workspace.pinned { parts.append("pinned") }
        if workspace.hasDiff {
            parts.append("\(workspace.additions) added, \(workspace.deletions) removed")
        }
        parts.append(
            workspace.lastActivityAt.formatted(
                .relative(presentation: .numeric, unitsStyle: .wide)
            )
        )
        return parts.joined(separator: ", ")
    }
}

/// What a Home row is filled with: nothing at rest, the hover tint under the pointer, the quiet
/// selection grey when it is the selected row.
///
/// It is handed to `List` as a `listRowBackground`, and it is opaque on purpose. AppKit paints its
/// own selection behind every row of an inset list, in the system accent while the table holds the
/// keyboard, and there is no way to ask it not to; a row background is drawn over the top of it,
/// so painting the pane's own ground here is what takes the blue bar away. That leaves the row's
/// selection entirely in Bloom's hands, which is the only way it could be made to match the
/// sidebar and the inspector.
///
/// The fill is `Palette.selected` whether or not the list has focus, and that is a deliberate
/// difference from `RowBackground`, whose emphasized branch exists for lists the arrow keys really
/// do drive with a live consequence. Arrowing down Home moves a highlight and opens nothing until
/// Return, so the emphatic fill would be promising something the list does not do.
struct HomeRowBackground: View {
    var isSelected: Bool
    var isHovered: Bool

    /// How far the fill stops short of the pane's edges. `List` adds an inset of its own that it
    /// does not expose (see `HomeMetrics.rowInset`), so this is measured against the rail rather
    /// than derived: it puts the fill's leading edge a spacing step outside the rail, which is
    /// where the sidebar's own selection sits relative to its glyphs.
    private static let inset: CGFloat = Metrics.spacing

    var body: some View {
        Palette.windowBackground
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .fill(fill)
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 1)
            }
    }

    private var fill: Color {
        if isSelected { return Palette.selected }
        return isHovered ? Palette.hover : .clear
    }
}
