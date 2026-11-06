import SwiftUI

/// Activation only pauses the scroll follower. Observing it on TranscriptListView invalidated
/// the whole list's body on every app switch, even when no rows had changed.
struct TranscriptWindowActivitySignal: View {
    let follower: TranscriptLiveEndFollower
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: activeState, initial: true) { _, state in
                follower.isWindowActive = state != .inactive
            }
            .onDisappear { follower.isWindowActive = false }
    }
}
