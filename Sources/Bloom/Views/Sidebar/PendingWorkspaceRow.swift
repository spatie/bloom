import SwiftUI
import BloomCore

/// A workspace being cut, in the source list, above the moment it exists.
///
/// Pressing Create dismissed the sheet onto a window where nothing happened until `git worktree
/// add` had finished, which on a real checkout is two or three seconds. This is the row that
/// stands there in the meantime. See `PendingWorkspace` for why it is not a `Workspace` and why
/// the id on it is the one the stored row will carry.
///
/// # It is drawn as a workspace row, on purpose
///
/// The same `Label`, the same `SidebarRowLabelStyle`, the same `rowIndent`, and the mark in the
/// same `SidebarMetrics.markColumn` box every other mark in the column is centred in. That is what
/// makes the swap invisible: when the stored row arrives it takes this row's id and this row's
/// place, at the same height with its name starting on the same pixel, and the only thing that
/// changes is that it becomes something you can click.
///
/// The mark is `.settingUp`, which is not a stand-in for a mark of its own. A worktree being cut
/// and a setup script installing dependencies are one thing to somebody watching the sidebar,
/// which is a workspace getting ready, and they run back to back: this row draws the spinner, the
/// stored row that replaces it draws the same spinner for as long as setup runs, and a reader sees
/// one state throughout rather than a mark that changes for a reason that means nothing to them. A
/// project with no setup script settles a beat sooner, which is the truth.
///
/// # What it deliberately does not do
///
/// It takes no selection, offers no menu, and cannot be dragged. There is nothing behind it: no
/// worktree to open, no transcript to read, no row to write a `sort_order` onto. Every one of
/// those is refused where the list is told about the row rather than here, in `SidebarView`, for
/// the same reason `SidebarWorkspaceRow` keeps `WorkspaceRow` a pure function of its inputs.
struct PendingWorkspaceRow: View {
    var pending: PendingWorkspace

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacing) {
                Text(pending.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A shade back from a workspace row's name, which is the one thing that says
                    // this row is not yet something you can go to. Not far back: it is the name
                    // the workspace is about to have, the reader chose it a second ago, and a row
                    // faded to a placeholder grey would read as disabled rather than as arriving.
                    .foregroundStyle(Palette.textSecondary)

                Spacer(minLength: 0)
            }
        } icon: {
            WorkspaceStatusGlyph(status: .settingUp)
        }
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
        // One element, because there is nothing in it to navigate between, and a value rather than
        // a second label so a screen reader says the name and then what is happening to it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(pending.name))
        .accessibilityValue(Text("Creating"))
        .help("Creating this workspace")
    }
}
