import SwiftUI
import BloomCore

/// The "may the Mac fall asleep while agents are working" row, as a section the General pane can
/// drop in.
///
/// A section of its own rather than a loose `Toggle`, because it is the only row in that pane that
/// needs a sentence under it saying what it does not do. Lid closed is not idle sleep, and no
/// application on macOS can hold a MacBook open through it. People will otherwise find that out by
/// losing a turn.
///
/// The same value is offered as the first item of the menu bar item's menu. Both read and write
/// `SleepPrevention.settingKey` and neither caches it, so a change on either surface shows up on
/// the other with no wiring between them.
struct SleepSettingsSection: View {
    @AppStorage(SleepPrevention.settingKey) private var preventsSleep = SleepPrevention.isOnByDefault

    var body: some View {
        Section {
            // A switch with its explanation underneath, matching the menu bar row above it in the
            // same pane.
            Toggle(isOn: $preventsSleep) {
                Text(SleepPrevention.settingTitle)
                Text(SleepPrevention.settingDetail)
            }
        } footer: {
            Text(SleepPrevention.caveat)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
