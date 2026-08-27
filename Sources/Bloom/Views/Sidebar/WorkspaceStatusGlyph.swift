import SwiftUI
import BloomCore

/// The mark at the head of a workspace row, and the same mark in the legend that explains it.
///
/// One type for both, because the two copies had already drifted: the legend drew the branch mark
/// in tertiary where the row draws it in secondary, and it named four of the thirteen states.
///
/// Every state is a different shape, not only a different colour, so the column can be read at a
/// glance and by someone who cannot tell the red one from the green one. That rule is why a draft
/// pull request is a pencil rather than the open pull request's triangle in a paler grey, and why a
/// closed one is a slash rather than the failing checks' cross without its fill. Both of those
/// pairs used to differ in colour alone.
struct WorkspaceStatusGlyph: View {
    var status: WorkspaceStatus
    /// Set on a row sitting on the accent selection fill, where every meaning colour in the palette
    /// is unreadable and the shape has to carry the meaning on its own.
    var isOnSelection = false

    var body: some View {
        content
            .frame(width: Metrics.glyph, height: Metrics.glyph)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .settingUp:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .running:
            // The one dot the whole window says "working" with, at this column's size. See
            // `WorkspaceRunningGlyph` for what it replaced and why, and `BusyPulse` for why every
            // lit row in the column moves together.
            WorkspaceRunningGlyph(isOnSelection: isOnSelection)
        default:
            Image(systemName: Self.symbol(for: status))
                // The unread mark is a dot rather than a symbol, so it is drawn a size down.
                .font(status == .unread ? Typo.micro : Typo.caption)
                // One weight for the whole column, because at eleven points beside
                // `xmark.circle.fill` the open pull request's mark read as a hairline, which is
                // what was reported. It cannot be answered by filling it: `arrow.triangle.pull`,
                // `arrow.triangle.merge` and `arrow.triangle.branch` are three strokes each and
                // SF Symbols ships no `.fill` for any of the three, so weight is the only thing
                // that gives them mass without giving them a different shape, and shape is what
                // this column tells states apart by. On the column rather than on those three,
                // because an exception list of symbol names drifts the first time one is
                // swapped; the marks that are already solid barely move at semibold, which is
                // the mass the stroked ones are being brought up to.
                .fontWeight(.semibold)
                .foregroundStyle(
                    isOnSelection ? AnyShapeStyle(Palette.textInverted) : Self.tint(for: status)
                )
        }
    }

    static func symbol(for status: WorkspaceStatus) -> String {
        switch status {
        case .settingUp, .running: ""
        // A raised hand, which is the same shape the menu bar strip and the opened ask row use, so
        // the three places this is reported say it with one mark. Filled rather than outlined: it
        // outranks every other state in the column and has to read at a glance among a dozen rows.
        case .awaitingPermission: "hand.raised.fill"
        case .setupFailed: "exclamationmark.triangle.fill"
        case .unread: "circle.fill"
        case .merged: "arrow.triangle.merge"
        case .closed: "slash.circle"
        // The stop sign, and the only octagon here. Filled, because it is the worst news GitHub
        // reports about a pull request that is still open and has to carry that weight among a
        // dozen rows. Not a second cross and not a second ring: `xmark.circle.fill` and
        // `slash.circle` are the two marks it would otherwise be taken for, and neither of them
        // means "nothing merges until a person does something". It shares its exclamation mark
        // with the failed setup, which is a triangle, and the rule this column keeps is that no
        // two states share a SHAPE.
        case .conflicted: "exclamationmark.octagon.fill"
        case .checksFailing: "xmark.circle.fill"
        case .checksRunning: "clock"
        case .checksPassed: "checkmark.circle.fill"
        // Bare, not `pencil.circle`: inside a ring it reads as the closed state's slash at the
        // size this column is drawn at.
        case .draft: "pencil"
        case .pullRequestOpen: "arrow.triangle.pull"
        case .changed: "arrow.triangle.branch"
        case .clean: "circle.dotted"
        }
    }

    /// The palette's own meaning colours, at the palette's own volume.
    ///
    /// This column is why they are as quiet as they are. A dozen of these are read at once down
    /// 260 points, and at `systemRed` and `systemGreen`'s volume the column reads as a warning
    /// light panel rather than as an index of what each agent is doing. That was fixed where it
    /// belongs, in `Palette`, rather than with a second set of colours here.
    static func tint(for status: WorkspaceStatus) -> AnyShapeStyle {
        switch status {
        // The caution colour, which is what a denied call and a failed setup are already drawn in.
        // Not the alarm red: nothing has gone wrong here, something is being asked.
        case .awaitingPermission, .setupFailed, .checksRunning: AnyShapeStyle(Palette.warning)
        // The same red as a failing check, and it shares it for the same reason the three warning
        // states share amber: the colour says how bad the news is and the shape says what the news
        // is. A fourth meaning colour invented for one state would say neither.
        case .conflicted, .checksFailing: AnyShapeStyle(Palette.negative)
        // The accent is the palette's "this went well": it has no green of its own, and
        // `Palette.positive` says why.
        case .checksPassed: AnyShapeStyle(Palette.positive)
        // Merged used to share that colour and differ from it only in shape. It has its own now:
        // `Palette.merged` is what a landed pull request is drawn in throughout the app, and this
        // column is the other place it is reported. A merge is not the same news as a green check
        // and no longer says it in the same colour.
        case .merged: AnyShapeStyle(Palette.merged)
        // The accent is what the app uses for "this is waiting for you" rather than for a machine,
        // which is exactly what an unread turn and an open pull request are.
        case .unread, .pullRequestOpen: AnyShapeStyle(Palette.accent)
        case .running: AnyShapeStyle(Palette.running)
        case .changed: AnyShapeStyle(.secondary)
        // Written out rather than left to a `default`, so a sixteenth status has to be given a
        // colour instead of silently taking the quietest one. `symbol(for:)` twenty lines above
        // is exhaustive and breaks the build on a new case; this one did not, so the two could
        // disagree about whether a new state had been thought about.
        case .settingUp, .closed, .draft, .clean: AnyShapeStyle(.tertiary)
        }
    }
}
