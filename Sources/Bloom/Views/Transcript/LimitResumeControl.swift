import SwiftUI
import BloomCore

/// Under a turn that hit the account's allowance: a button to continue once it is back, and while
/// that is waiting, what it is waiting for and a way to call it off. See `LimitResume`.
struct LimitResumeControl: View {
    var watch: LimitResumeWatch
    var arm: () -> Void
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: TranscriptLayout.block) {
            if let step = watch.step {
                Text(step.sentence())
                    .foregroundStyle(Palette.textSecondary)
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Continue when the limit resets", action: arm)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Sends “\(LimitResume.prompt)” once a usage reading shows the limit has reset")
            }
        }
        .font(Typo.caption)
    }
}
