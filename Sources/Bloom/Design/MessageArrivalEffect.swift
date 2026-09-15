import BloomCore
import SwiftUI

extension View {
    func messageArrival(_ arrival: MessageArrival?) -> some View {
        modifier(MessageArrivalEffect(arrival: arrival))
    }
}

/// Time belongs to the message, not the hosting cell. This survives the instant-to-saved handoff
/// and ignores the table's animation-free layout transaction. Only these drawing attributes tick;
/// the supplied content is not rebuilt or re-parsed by the timeline closure.
private struct MessageArrivalEffect: ViewModifier {
    let arrival: MessageArrival?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finishedArrival: MessageArrival?

    func body(content: Content) -> some View {
        // Sent bubbles enter through the composer's occlusion as the transcript scrolls.
        // A second fade, scale and offset on the row made that one movement look disconnected.
        if let arrival, arrival.style == .reply {
            let finished = finishedArrival == arrival
            TimelineView(.animation(paused: finished || reduceMotion)) { context in
                let pose = finished ? .settled : arrival.pose(at: context.date, reduceMotion: reduceMotion)
                content
                    .opacity(pose.opacity)
                    .scaleEffect(pose.scale, anchor: .bottomTrailing)
                    .offset(y: pose.rise)
            }
            .task(id: arrival) {
                let remaining = arrival.remaining(at: Date())
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled else { return }
                finishedArrival = arrival
            }
        } else {
            content
        }
    }
}
