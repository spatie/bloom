import SwiftUI
import BloomCore

/// Every check state on one page, and the case the mark was reported from.
///
/// The report was a screenshot of a real branch: thirteen rows, eleven passed and two still
/// running, and the two running ones read as absent rather than as busy. That is not a state one
/// row can be judged in. It is a comparison against the column the row sits in, so the page leads
/// with that exact list and the mark is either the first thing found in it or it is not fixed.
///
/// It renders offscreen through `--snapshot`, unlike the other check surfaces: there is no
/// representable anywhere in a `CheckRunRow`, so `ImageRenderer` draws the real thing rather than
/// a yellow placeholder.
///
///     Bloom --snapshot /tmp/shots        check-runs-light.png, check-runs-dark.png
struct CheckRunSnapshotGallery: View {
    /// The inspector column at the width it opens at, so the truncation and the spacing are the
    /// ones a reader actually gets.
    private static let column: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Eleven passed, two running: the reported case") {
                rows(Self.branch)
            }

            group("Every state, in the order they occur") {
                rows(Self.everyState)
            }

            // The accessibility property the column is held to: on a selected row `CheckRunRow`
            // drops the tint, so the mark alone has to say which state this is. A filled disc
            // beside a tick and a cross still does.
            group("On a selected row, where the tint is dropped") {
                VStack(spacing: 0) {
                    ForEach(Self.everyState) { run in
                        CheckRunRow(run: run)
                            .background(Palette.selectedEmphasized)
                            .environment(\.isOnEmphasizedSelection, true)
                    }
                }
                .frame(width: Self.column, alignment: .leading)
            }
        }
        .padding(16)
    }

    private func rows(_ runs: [CheckRun]) -> some View {
        VStack(spacing: 0) {
            ForEach(runs) { CheckRunRow(run: $0) }
        }
        .frame(width: Self.column, alignment: .leading)
        .background(Palette.surface)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // No `foregroundStyle`. `Palette.textSecondary` is an AppKit semantic colour, and
            // `ImageRenderer` resolves those against the process appearance rather than the
            // `colorScheme` it is handed, so on the dark page every heading came out black on
            // black. The default label colour follows the scheme and is what the rows use.
            Text(title)
                .font(Typo.caption)
            content()
        }
    }

    // MARK: - Runs

    private static let started = Date(timeIntervalSince1970: 1_770_000_000)

    private static func passed(_ name: String, seconds: TimeInterval) -> CheckRun {
        CheckRun(
            name: name,
            status: "COMPLETED",
            conclusion: "SUCCESS",
            detailsURL: "https://example.invalid/\(name)",
            startedAt: started,
            completedAt: started.addingTimeInterval(seconds),
            workflowName: "tests"
        )
    }

    private static func running(_ name: String) -> CheckRun {
        CheckRun(
            name: name,
            status: "IN_PROGRESS",
            conclusion: "",
            detailsURL: "https://example.invalid/\(name)",
            startedAt: started,
            workflowName: "tests"
        )
    }

    /// The reported branch. The two running rows are not put together and are not at the top:
    /// scattered through the list is where they were hard to find.
    private static let branch: [CheckRun] = [
        passed("build (macos-15)", seconds: 214),
        passed("build (macos-26)", seconds: 233),
        running("lint"),
        passed("unit (BloomCore)", seconds: 61),
        passed("unit (BridgeShim)", seconds: 44),
        passed("unit (Store)", seconds: 96),
        passed("unit (Git)", seconds: 132),
        running("integration"),
        passed("spell", seconds: 8),
        passed("house rules", seconds: 5),
        passed("appcast", seconds: 12),
        passed("notarise", seconds: 401),
        passed("danger", seconds: 19),
    ]

    private static let everyState: [CheckRun] = [
        CheckRun(name: "Queued", status: "QUEUED", conclusion: "", workflowName: "tests"),
        running("Running"),
        passed("Passed", seconds: 61),
        CheckRun(
            name: "Failed",
            status: "COMPLETED",
            conclusion: "FAILURE",
            startedAt: started,
            completedAt: started.addingTimeInterval(31),
            workflowName: "tests"
        ),
        CheckRun(name: "Skipped", status: "COMPLETED", conclusion: "SKIPPED", workflowName: "tests"),
        CheckRun(name: "No result", status: "COMPLETED", conclusion: "", workflowName: "tests"),
    ]
}
