import SwiftUI
import BloomCore

/// One workspace on Home, on two lines.
///
/// The order across the row is the order the questions are asked in. Something at the very leading
/// edge says "look here"; the project mark says whose work this is; the name says which piece of
/// it; under the name, the project spelled out and the branch say which worktree; the mark, the
/// counts and the age on the trailing edge say how it went and how long ago.
///
/// **It was one line, and the owner's complaint about the list was that the rows were thin with a
/// lot of air between the name and the numbers at the right.** He was describing a real hole: a
/// name at one edge and three columns at the other, with nothing between them on any row. The
/// second line fills it with the two things a person identifies a worktree by, which Home was the
/// only list in the window not showing. See `origin`.
///
/// **Why the project mark leads and the status mark does not.** In the sidebar the workspace sits
/// under its project's heading, so the leading slot is free for the status glyph and that is what
/// fills it. Home is flat and crosses every project, so the one thing that cannot be worked out
/// from anywhere else on the row is which project it belongs to. The status mark keeps its shape
/// and its colour, it simply moves to the trailing cluster where the rest of the outcome is.
///
/// **There is no rail.** There was: a short coloured bar at the leading edge of a row being worked
/// on or waiting for a person, in the tint `WorkspaceStatusGlyph` gives that state. The argument
/// for it was that it carried nothing on its own, since the same state is in the glyph's shape and
/// in the row's accessibility label, so it was free signal for a reader who already knew the
/// language.
///
/// **That is the argument it died on.** The owner's words on seeing it: "i don't know what that
/// blue and red line in front of those two items mean". A mark that has to be learned, on the
/// screen he opens first, sitting eleven points from a glyph that says the same thing in a shape
/// he can name, is not free signal. It is a second alphabet for a sentence already written. The
/// glyph stays, and it is the one that carries the state.
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
    /// Whether this rename has already been finished, so the ways of leaving the field cannot ask
    /// for the same rename twice. Reset when the field opens. See `end(_:)`.
    @State private var hasEnded = false
    @FocusState private var fieldFocused: Bool

    private var workspace: Workspace { row.workspace }

    /// A hairline is too thin to read as a colour and a full chip is a second badge. Three points
    /// is what a coloured edge marker is on a Mac. Local rather than in `Metrics` because nothing
    /// else in the window has one yet; a candidate for promotion if a second list grows one.

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
        HStack(spacing: Metrics.spacingWide) {
            RepoIcon(repo: row.repo)

            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                name
                origin
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        // Said rather than inherited, and this is what stops the list from bleaching the row.
        //
        // `List` still knows which row is selected, because the arrow keys need it to, and AppKit
        // still inverts a selected row's text to white for the accent fill it thinks it drew. The
        // fill is covered by `HomeRowBackground`; the inversion is not, and without this the
        // selected row's name went white on a pale grey plate and all but disappeared. Everything
        // on the row that carries a colour of its own (the glyph, the counts) already
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
        .frame(minHeight: HomeMetrics.rowHeight)
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

    /// The first line: what this workspace is called, and the two marks that travel with the name.
    @ViewBuilder
    private var name: some View {
        HStack(spacing: Metrics.spacing) {
            if isRenaming {
                TextField("Workspace name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { end(.submitted) }
                    .onExitCommand { end(.escaped) }
                    // Clicking away commits, as it does in Finder, rather than leaving the field
                    // open on the row holding text nobody ever asked to keep. Guarded on having
                    // had the focus, so the false the field starts at is not read as losing it.
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
                WorkspaceNameText(workspace, isUnread: isUnread)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Right after the name, the same place the sidebar puts it, so one workspace is
                // marked in one way in both lists. No accessibility label of its own: this row is
                // merged into a single element below, which would swallow it, so the colour is
                // said in `accessibilityLabel` instead.
                //
                // Nothing special for the archived case. The whole row is drained by `grayscale`
                // further down, which takes the dot with it, and that is the right answer: an
                // archived workspace cannot be given a colour or have one taken off.
                WorkspaceColourDot(hex: workspace.colour)

                if workspace.pinned {
                    Image(systemName: "pin.fill")
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// The second line: whose work this is, and which branch it is on.
    ///
    /// **The row was one line and it was the wrong one line.** A name at the leading edge and three
    /// numbers at the trailing edge left forty points of nothing between them on every row, on a
    /// screen whose whole complaint was that it looked sparse. What went in the gap is what a
    /// person actually identifies a worktree by and what Home was the only list not showing: the
    /// project, spelled rather than left to a 16 point monogram, and the branch.
    ///
    /// It also retired the search's match label. That existed because a row could be a perfect
    /// answer with nothing on it that looked like what was typed, and the two fields it stood in
    /// for, the branch and the project, are both on this line now, on every row, searching or not.
    private var origin: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if let repo = row.repo {
                Text(repo.name)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)

                Text(verbatim: "/")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary.opacity(0.5))
            }

            Text(workspace.branch)
                .font(Typo.codeTiny)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    /// Always occupies its width, so every name in the list starts on the same vertical line
    /// whether or not its row is marked.
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
                // The size stands IN the diff's slot rather than beside it, and that is the whole
                // of what Home's rows gained from the Storage pane.
                //
                // The same column because it answers the same question one state later: what this
                // workspace amounts to. An archived workspace's diff counts describe a worktree
                // that was removed when it was archived, which is the argument the `archivebox`
                // glyph two columns to the left already makes about its status, so nothing true is
                // covered up. And one slot rather than a fourth column is what keeps the age from
                // sliding sideways when the Archived chip is pressed.
                //
                // The diff below has no archived case of its own any more. Those two counts used
                // to drain their own hue, because they were the only thing on the row loud enough
                // to need it; the row now drains itself, and a second copy of that decision here
                // would be the one place the treatment could drift from the rest of the line.
                if let bytes = row.bytes {
                    Text(ArchiveDeletion.bytes(bytes))
                        .font(Typo.captionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                } else if workspace.hasDiff {
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

    /// Whether the name is set in the unread weight. Archived wins over unread, and the argument
    /// for that lives with the rule, in `WorkspaceUnreadMark`.
    ///
    /// It was written out here as `!row.isArchived && workspace.unread` with the whole argument
    /// restated above it, which made three copies of one rule in the app and a comment whose last
    /// line said the copies had to end the same way or they would disagree about one workspace.
    private var isUnread: Bool {
        WorkspaceUnreadMark.isUnread(workspace)
    }

    private var status: WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace,
            isRunning: isRunning,
            pullRequest: pullRequest,
            isAwaitingPermission: isAwaitingPermission
        )
    }

    // MARK: - Words

    private var statusDescription: String {
        row.isArchived ? "Archived" : status.summary(pullRequest: pullRequest)
    }

    /// The tooltip, which is where everything else the Storage pane drew ended up.
    ///
    /// The message and chat counts and the branch standing were columns on that screen and are a
    /// sentence here, because this row is three columns wide and they are worth reading once
    /// rather than scanning down. This is also the closest thing Home has to the sidebar's hover
    /// card: it is the row's own facts, unabbreviated, for a reader who has stopped on one row.
    /// See `ArchivedWorkspaceFootprint.contents`.
    private var help: String {
        var text = statusDescription
        if let repo = row.repo { text += " in \(repo.name)" }
        if let footprint = row.footprint { text += " \u{00B7} \(footprint.contents)" }
        return text
    }

    /// Everything the row shows, as one sentence, with the state in it rather than only the name.
    /// A list read by ear is unusable if every row announces "some-branch-name, 267, 109".
    private var accessibilityLabel: String {
        var parts = [workspace.name]
        if let repo = row.repo { parts.append("in \(repo.name)") }
        // Said out loud, because on a search this is the only thing on the row that explains why
        // the row is there at all.
        if let match = row.match { parts.append("matched \(match)") }
        parts.append(statusDescription)
        if let colour = workspace.colourDescription { parts.append("colour \(colour)") }
        if workspace.pinned { parts.append("pinned") }
        // Whichever of the two the trailing slot is actually drawing, in the same order, so the
        // row read by ear and the row read by eye carry the same facts.
        if let bytes = row.bytes {
            parts.append("holding \(ArchiveDeletion.bytes(bytes))")
        } else if workspace.hasDiff {
            parts.append("\(workspace.additions) added, \(workspace.deletions) removed")
        }
        parts.append(
            workspace.lastActivityAt.formatted(
                .relative(presentation: .numeric, unitsStyle: .wide)
            )
        )
        return parts.joined(separator: ", ")
    }

    // MARK: - Renaming

    /// One door out of the field, for each of the ways of leaving it. Which of them writes the
    /// name is `InPlaceRename` in the core, so this row, the sidebar's and the project header's
    /// cannot answer the same gesture three different ways.
    ///
    /// `hasEnded` is what stops one rename being asked for twice: committing closes the field,
    /// which is itself a focus change, and the write is asynchronous so the second caller would
    /// still see the old name.
    private func end(_ ending: InPlaceRename.Ending) {
        guard !hasEnded else { return }
        hasEnded = true
        guard case .commit(let name) = InPlaceRename.outcome(
            ending, draft: draft, current: workspace.name
        ) else { return onCancelRename() }
        onCommitRename(name)
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
