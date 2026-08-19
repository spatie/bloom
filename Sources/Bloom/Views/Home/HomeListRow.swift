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
/// weight of the name.
struct HomeListRow: View {
    var row: HomeRow
    var isRunning: Bool
    var now: Date
    /// Whether this is the row the list has selected, and whether the list has the keyboard.
    ///
    /// Passed in rather than read from `\.backgroundProminence`, which is what the sidebar's rows
    /// use. That environment value is only set for us by `.listStyle(.sidebar)`; under the inset
    /// style a selected row is painted with the accent and told nothing about it, so the project
    /// tile kept its own colour and the diff counts stayed green and red on a blue bar.
    var isSelected: Bool
    var isListFocused: Bool

    /// AppKit fills a selected row with the accent only while the list holds the keyboard in an
    /// active window, and with a quiet grey otherwise. Inverting on anything less than all three
    /// draws white text on that grey.
    @Environment(\.controlActiveState) private var activeState

    private var workspace: Workspace { row.workspace }

    private var isEmphasized: Bool {
        isSelected && isListFocused && activeState == .key
    }

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

            WorkspaceNameText(workspace)
                .fontWeight(workspace.unread ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)

            if workspace.pinned {
                Image(systemName: "pin.fill")
                    .font(Typo.micro)
                    .foregroundStyle(
                        isEmphasized ? Palette.selectedEmphasizedText : Palette.textTertiary
                    )
                    .accessibilityHidden(true)
            }

            Spacer(minLength: Metrics.spacingWide)

            trailing
        }
        // Dimmed as a whole rather than colour by colour. An archived workspace still has a
        // project mark, a diff and an age, and picking a quieter variant of each of them
        // would be four decisions where the row only makes one: this is over.
        .opacity(row.isArchived ? 0.55 : 1)
        .frame(minHeight: Metrics.rowHeight)
        // The whole row, including the gap the name does not fill, is the click target. Without
        // it only the text is, and a list where half of each row ignores the pointer feels broken
        // long before anyone works out why.
        .contentShape(Rectangle())
        // Merged into one sentence. Left as separate elements, VoiceOver reads a name, a repeated
        // project name, two bare numbers and "1d", in that order, which says nothing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityInputLabels([workspace.name])
        .accessibilityAddTraits(.isButton)
        .help(help)
        // The counts and the glyph carry their own colours, and the list inverts a selected row's
        // text without knowing about them. This is the same signal the sidebar's rows send.
        .environment(\.isOnEmphasizedSelection, isEmphasized)
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
    private var trailing: some View {
        HStack(spacing: Metrics.spacingWide) {
            if row.isArchived {
                // An archived worktree is gone, so "checks passed" or "has changes" would be a
                // report about something that no longer exists.
                Image(systemName: "archivebox")
                    .font(Typo.caption)
                    .foregroundStyle(
                        isEmphasized ? Palette.selectedEmphasizedText : Palette.textTertiary
                    )
                    .frame(width: Metrics.glyph, height: Metrics.glyph)
                    .accessibilityHidden(true)
            } else {
                WorkspaceStatusGlyph(status: status, isOnSelection: isEmphasized)
                    .accessibilityHidden(true)
            }

            // A real container rather than a `Group` around the condition. A frame on a `Group`
            // is applied to each of its children, so an empty one keeps no width at all and the
            // status mark to its left slid two centimetres right on every row without a diff.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
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
                .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textTertiary)
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

    private var status: WorkspaceStatus {
        WorkspaceStatus.resolve(
            workspace: workspace, isRunning: isRunning, pullRequest: pullRequest
        )
    }

    /// Resting states get no rail. A rail on every row is a stripe down the edge of the list, and
    /// the point of it is that only a few rows have one.
    private var showsRail: Bool {
        !row.isArchived && status.homeLane != .resting
    }

    private var railTint: AnyShapeStyle {
        isEmphasized
            ? AnyShapeStyle(Palette.selectedEmphasizedText)
            : WorkspaceStatusGlyph.tint(for: status)
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
