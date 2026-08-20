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
            // The figure that builds itself, not the pulsing dot that used to be here. See
            // `WorkspaceRunningGlyph` for why the row has one moving part rather than two, and
            // `BusyPulse` for why every lit row in the column moves together.
            WorkspaceRunningGlyph(isOnSelection: isOnSelection)
        default:
            Image(systemName: Self.symbol(for: status))
                // The unread mark is a dot rather than a symbol, so it is drawn a size down.
                .font(status == .unread ? Typo.micro : Typo.caption)
                .foregroundStyle(
                    isOnSelection ? AnyShapeStyle(Palette.textInverted) : Self.tint(for: status)
                )
        }
    }

    static func symbol(for status: WorkspaceStatus) -> String {
        switch status {
        case .settingUp, .running: ""
        case .setupFailed: "exclamationmark.triangle.fill"
        case .unread: "circle.fill"
        case .merged: "arrow.triangle.merge"
        case .closed: "slash.circle"
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
        case .setupFailed, .checksRunning: AnyShapeStyle(Palette.warning)
        case .checksFailing: AnyShapeStyle(Palette.negative)
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
        default: AnyShapeStyle(.tertiary)
        }
    }
}
