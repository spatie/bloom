import SwiftUI
import BloomCore

/// The "check for updates automatically" row, as a section the General pane can drop in.
///
/// A section of its own for the same reason `SleepSettingsSection` is one: it is the pane's only
/// switch that has to explain when it will and will not interrupt, and on a build that cannot
/// update itself there is no switch to show at all, only the reason why.
///
/// Deliberately not `@AppStorage`. The preference behind this switch is Sparkle's
/// `automaticallyChecksForUpdates`, which Sparkle persists in the app's defaults itself and which
/// resets its own check schedule when it moves. Sparkle's documentation is explicit that an app
/// must not keep a second user default beside it, and a second one is precisely how the menu bar
/// switch once ended up showing off while the thing it controlled was on. So this reads and writes
/// the one value, through `SoftwareUpdater`, and the default for it lives in `Info.plist` under
/// `SUEnableAutomaticChecks`.
struct UpdateSettingsSection: View {
    private let updater = SoftwareUpdater.shared

    var body: some View {
        Section(SoftwareUpdate.sectionTitle) {
            if let explanation = SoftwareUpdate.unavailableExplanation(updater.availability) {
                LabeledContent(SoftwareUpdate.settingTitle) {
                    Text(explanation)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                // A switch with its explanation underneath, matching every other boolean in this
                // window.
                Toggle(isOn: checksAutomatically) {
                    Text(SoftwareUpdate.settingTitle)
                    Text(SoftwareUpdate.settingDetail)
                }

                Button("Check for Updates Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private var checksAutomatically: Binding<Bool> {
        Binding(
            get: { updater.checksAutomatically },
            set: { updater.setChecksAutomatically($0) }
        )
    }
}
