import SwiftUI
import BloomCore

/// The welcome window's lid step: approve the helper once, and Keep Awake can hold a closed lid
/// for the rest of the app's life.
///
/// **Asked here because asking later does not work.** The approval is a trip to System Settings,
/// and a switch that needs one is a switch people flip, watch do nothing, and never touch again.
/// Offered on the screen after the checks, on a Mac that has a lid, it is two presses while
/// somebody is already setting things up.
struct WelcomeKeepAwake: View {
    @State private var sleepSwitch = SleepSwitch.shared
    @State private var keepAwake = KeepAwakeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane - Metrics.spacingSmall) {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                Text("Keep this Mac awake with the lid closed")
                    .font(Typo.displayHeading)
                    .foregroundStyle(Palette.textPrimary)

                Text(
                    "Agents stop when the Mac sleeps, and closing the lid sleeps it whatever an "
                        + "app asks for. Bloom can hold it open, but only through a small helper "
                        + "macOS makes you approve."
                )
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: Metrics.spacing) {
                standing

                Text(
                    "Bloom works without this. Keep Awake still holds the Mac open while the lid "
                        + "is up, and Settings has this switch again under Menu Bar."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var standing: some View {
        switch sleepSwitch.standing {
        case .ready:
            Label {
                Text(keepAwake.keepsLidClosed
                    ? "Approved. A Keep Awake session now holds the lid too."
                    : "Approved. Switch the lid option on whenever you want it.")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.positive)
            }
            .font(Typo.body)
            .foregroundStyle(Palette.textPrimary)
        case .needsApproval:
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Button("Set Up Keep Awake") { setUp() }
                    .buttonStyle(.borderedProminent)
                Text("System Settings opens on Login Items, where Bloom's helper is waiting to be allowed.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        case .unavailable(let reason):
            Text("This copy of Bloom cannot install the helper: \(reason)")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Registers the helper and, when that is all it takes, switches the lid option on. Somebody
    /// who pressed this button asked for the thing, so the preference follows the press rather
    /// than waiting to be found in Settings afterwards.
    private func setUp() {
        switch sleepSwitch.enable() {
        case .ready:
            keepAwake.keepsLidClosed = true
        case .needsApproval:
            keepAwake.keepsLidClosed = true
            sleepSwitch.openApprovalSettings()
        case .unavailable:
            break
        }
    }
}
