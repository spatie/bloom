import SwiftUI
import BloomCore

/// The card under an empty server's heading that offers its first project.
///
/// A card rather than a row in the list's own grammar, because it is the one thing in the column
/// that is saying something rather than listing something, and it only ever appears once per
/// server. When it shows and when it retires is `ServerFirstProjectNudge`'s; this is the drawing.
///
/// Drawn on `surfaceRaised` with the `border` rule, which is `NoticeBanner`'s card, so the two
/// things in the window that talk to the owner unprompted read as the same kind of thing.
struct ServerFirstProjectCard: View {
    var serverName: String
    var onStartProject: () -> Void
    var onDismiss: () -> Void

    @State private var dismissHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("Your server is ready")
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            } icon: {
                // Brand ink rather than the control accent: it marks the card, it is not a control.
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }
            .font(Typo.label)
            // Clear of the close button, which sits over the title's trailing edge.
            .padding(.trailing, Metrics.headerButton.width)

            // The copy promises what the remote Start a Project window offers and no more: a name
            // or a path on the server, and Browse GitHub…, which needs GitHub signed in there.
            Text("Clone a GitHub repository or add a folder on \(serverName) to start working there.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
                .padding(.bottom, Metrics.spacingWide)
                .padding(.trailing, 10)

            Button("Start a Project…", action: onStartProject)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Palette.controlAccent)
                .help("Clone a GitHub repository or add a folder on \(serverName)")
        }
        .padding(.top, 9)
        .padding([.leading, .trailing, .bottom], 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        )
        .overlay(alignment: .topTrailing) { dismissButton }
        .padding(.vertical, Metrics.spacingSmall)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your server is ready")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Label("Dismiss", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(Typo.micro)
                .frame(width: 16, height: 16)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                .background(dismissHovered ? Palette.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        .buttonStyle(.plain)
        // Tertiary at rest, as `NoticeBanner`'s cross is: a way out rather than the thing to do.
        .foregroundStyle(dismissHovered ? Palette.textPrimary : Palette.textTertiary)
        .onHoverChange { dismissHovered = $0 }
        .help("Dismiss")
        .accessibilityHint("Hides this card for this server")
        .padding(.top, 7)
        .padding(.trailing, 6)
    }
}
