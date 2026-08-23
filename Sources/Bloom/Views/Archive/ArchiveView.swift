import SwiftUI
import BloomCore

/// Everything that has been archived, what each row still costs, and the one way to destroy it.
///
/// Archived workspaces have been readable since `ArchivedWorkspaceView`, one at a time, reached
/// from a greyed row on Home. What there has never been is the other view of them: all of them at
/// once, in the order that matters when a database has grown, with the number that says which one
/// is worth doing anything about. A workspace an agent worked in for a week can hold hundreds of
/// megabytes of transcript, and until now nothing in Bloom could say so or take it back.
///
/// Every decision on this screen is `ArchiveCleanup`, `ArchivedWorkspaceFootprint` and
/// `ArchiveDeletion` in the core: what the bytes are, how the list is ordered, what the
/// confirmation says. What is left here is where the pixels go.
struct ArchiveView: View {
    @Environment(AppModel.self) private var app

    @State private var cleanup = ArchiveCleanup(footprints: [])
    @State private var size: DatabaseSize?
    @State private var order: ArchiveCleanupOrder = .largest
    @State private var selected: Set<WorkspaceID> = []
    @State private var hovered: WorkspaceID?
    @State private var confirming: ArchiveDeletion?
    @State private var isLoaded = false
    @State private var isCompacting = false

    /// Where the size column starts, so every figure in the list is right aligned against the same
    /// edge whatever it says. A column that shifts by the width of "1.2 GB" is a column the eye
    /// cannot run down.
    private static let sizeColumn: CGFloat = 76
    private static let ageColumn: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            // No strip over an empty screen. The order control has nothing to order and the total
            // has nothing to total, and a bar of dead controls above a "nothing here yet" is the
            // reason empty states so often read as a broken screen rather than a new one.
            if !cleanup.isEmpty {
                bar
                Hairline()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackground)
        .task(id: app.archivedRevision) { await load() }
        .confirmation($confirming) { deletion in
            Confirmation(
                title: deletion.title,
                message: deletion.message,
                confirmLabel: deletion.confirmLabel,
                cancelLabel: deletion.cancelLabel,
                tone: .destructive
            )
        } onConfirm: { deletion in
            Task { await delete(deletion) }
        }
    }

    // MARK: - The strip across the top

    private var bar: some View {
        HStack(spacing: Metrics.gutter) {
            Picker("Order", selection: $order) {
                ForEach(ArchiveCleanupOrder.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Spacer(minLength: Metrics.spacing)

            if !selected.isEmpty {
                Text(summaryOfSelection)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .layoutPriority(-1)

                Button("Delete\u{2026}") { confirming = ArchiveDeletion(cleanup.selected(selected, order: order)) }
                    .controlSize(.small)
                    .foregroundStyle(Palette.negative)
            } else if !cleanup.isEmpty {
                Text(summaryOfEverything)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .layoutPriority(-1)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.barHeight)
        .tabStripMaterial()
    }

    private var summaryOfEverything: String {
        "\(count(cleanup.footprints.count, "archived workspace")), holding \(ArchiveDeletion.bytes(cleanup.totalBytes))"
    }

    private var summaryOfSelection: String {
        let rows = cleanup.selected(selected, order: order)
        let bytes = rows.reduce(0) { $0 + $1.totalBytes }
        return "\(count(rows.count, "workspace")) selected, \(ArchiveDeletion.bytes(bytes))"
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if !isLoaded {
            LoadingView()
        } else if cleanup.isEmpty {
            ContentUnavailableView {
                Label("Nothing has been archived", systemImage: "archivebox")
            } description: {
                Text(
                    "Archiving a workspace removes its worktree and keeps everything it said. "
                    + "When there is something here, this is where you can see what that costs."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                list
                Hairline()
                footer
            }
        }
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(cleanup.ordered(by: order)) { footprint in
                row(footprint)
                    .tag(footprint.id)
                    .listRowInsets(EdgeInsets(
                        top: Metrics.spacingSmall, leading: Metrics.gutter,
                        bottom: Metrics.spacingSmall, trailing: Metrics.gutter
                    ))
                    .onHoverChange {
                        hovered = $0 ? footprint.id : (hovered == footprint.id ? nil : hovered)
                    }
                    .listRowBackground(HomeRowBackground(
                        isSelected: selected.contains(footprint.id),
                        isHovered: hovered == footprint.id
                    ))
                    .contextMenu {
                        Button("Read the Transcript") { app.openArchived(footprint.workspace) }
                        Divider()
                        // Through `ArchiveCleanup.target` rather than straight to this row,
                        // and the selection is moved to whatever comes back. That keeps the one
                        // thing this screen cannot afford to get wrong: the strip's count and the
                        // confirmation's count are the same list, so they cannot say two different
                        // numbers about the same irreversible delete. See `target` for the bug.
                        Button("Delete Permanently\u{2026}", role: .destructive) {
                            let rows = cleanup.target(footprint.id, selection: selected, order: order)
                            selected = Set(rows.map(\.id))
                            confirming = ArchiveDeletion(rows)
                        }
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// A row, and under it a bar as wide as its share of the largest row.
    ///
    /// The bar is the only ornament on this screen and it is here because it is the answer to the
    /// question the screen was opened with. A column of sizes says which figure is biggest only
    /// after the reader has compared eight numbers in three different units; the bar says it
    /// before the numbers are read at all, and picks out the two rows that are the whole problem
    /// from the thirty that are rounding error.
    private func row(_ footprint: ArchivedWorkspaceFootprint) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(footprint.workspace.name)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    Text(subtitle(footprint))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Metrics.spacingWide)

                Text(relativeAge(footprint))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: Self.ageColumn, alignment: .trailing)

                Text(ArchiveDeletion.bytes(footprint.totalBytes))
                    .font(Typo.captionEmphasis)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Self.sizeColumn, alignment: .trailing)
            }

            shareBar(footprint)
        }
        .padding(.vertical, Metrics.spacingTight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(footprint))
    }

    private func shareBar(_ footprint: ArchivedWorkspaceFootprint) -> some View {
        GeometryReader { proxy in
            let largest = cleanup.footprints.map(\.totalBytes).max() ?? 0
            let share = largest > 0 ? Double(footprint.totalBytes) / Double(largest) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.border.opacity(0.5))
                // A minimum of two points, so a workspace holding almost nothing still draws
                // something. A bar of zero width reads as a missing row rather than a small one.
                Capsule()
                    .fill(Palette.accent.opacity(0.55))
                    .frame(width: max(2, proxy.size.width * share))
            }
        }
        .frame(height: 2)
    }

    /// Project, branch, and what the transcript is made of. The branch is named because it is what
    /// decides whether this record is the last thing left of the work.
    private func subtitle(_ footprint: ArchivedWorkspaceFootprint) -> String {
        var parts = [footprint.repoName, footprint.workspace.branch]
        if footprint.messageCount > 0 {
            parts.append("\(count(footprint.messageCount, "message")) in \(count(footprint.sessionCount, "chat"))")
        }
        if footprint.branchIsLocal == false {
            parts.append("branch not on this Mac")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func relativeAge(_ footprint: ArchivedWorkspaceFootprint) -> String {
        footprint.archivedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private func accessibilityLabel(_ footprint: ArchivedWorkspaceFootprint) -> String {
        [
            footprint.workspace.name,
            footprint.repoName,
            "archived \(footprint.archivedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))",
            "holding \(ArchiveDeletion.bytes(footprint.totalBytes))",
        ].joined(separator: ", ")
    }

    // MARK: - The database, and giving the space back

    /// Why the list's total and the file's size are two different numbers, said where a person
    /// looking at both of them can read it.
    ///
    /// **Deleting rows does not shrink the file.** SQLite puts the pages on a free list and reuses
    /// them, which is right and is also the reason a delete of half a gigabyte changes nothing in
    /// Finder. This strip is where that is admitted, and where the slow thing that actually gives
    /// the space back is offered rather than done to somebody by surprise.
    @ViewBuilder
    private var footer: some View {
        if let size {
            HStack(spacing: Metrics.gutter) {
                Text(databaseLine(size))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Metrics.spacing)

                if size.isWorthCompacting {
                    Button(isCompacting ? "Compacting" : "Compact the database") {
                        Task { await compact() }
                    }
                    .controlSize(.small)
                    .disabled(isCompacting)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.inset)
            .background(Palette.surfaceSunken)
        }
    }

    private func databaseLine(_ size: DatabaseSize) -> String {
        guard size.isWorthCompacting else {
            return "Bloom\u{2019}s database is \(ArchiveDeletion.bytes(size.totalBytes))."
        }
        return """
        Bloom\u{2019}s database is \(ArchiveDeletion.bytes(size.totalBytes)), of which \
        \(ArchiveDeletion.bytes(size.freeBytes)) is space nothing is using. Deleting frees pages \
        inside the file; compacting rewrites the file and hands them back to the disk, which takes \
        a while and stops everything else while it runs.
        """
    }

    // MARK: - Doing it

    private func load() async {
        cleanup = await app.archiveCleanup()
        size = await app.databaseSize()
        selected = selected.intersection(cleanup.footprints.map(\.id))
        isLoaded = true
    }

    private func delete(_ deletion: ArchiveDeletion) async {
        await app.deleteArchived(deletion.footprints.map(\.id))
        selected = []
        await load()
    }

    private func compact() async {
        isCompacting = true
        await app.compactDatabase()
        size = await app.databaseSize()
        isCompacting = false
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }
}
