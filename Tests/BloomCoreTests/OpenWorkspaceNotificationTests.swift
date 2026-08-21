import Combine
import Foundation
import Testing
@testable import BloomCore

/// The round trip that four of the six posters were failing.
///
/// Every test here runs on a `NotificationCenter` of its own, so nothing the suite does can reach
/// the one a running app listens on.
@Suite("Open workspace notification")
struct OpenWorkspaceNotificationTests {
    @Test("an id posted is the id delivered")
    func roundTrips() {
        let centre = NotificationCenter()
        let received = Received()

        let subscription = OpenWorkspaceNotification.publisher(on: centre)
            .sink { received.ids.append($0) }
        OpenWorkspaceNotification.post(WorkspaceID("w1"), on: centre)
        OpenWorkspaceNotification.post(WorkspaceID("w2"), on: centre)
        subscription.cancel()
        OpenWorkspaceNotification.post(WorkspaceID("w3"), on: centre)

        #expect(received.ids == [WorkspaceID("w1"), WorkspaceID("w2")])
    }

    /// The bug, written down. The channel used to be posted to by name from six places, four of
    /// them with a `WorkspaceID` and two with a bare `String`, against a reader casting to
    /// `String`. Posting the old way still reaches nobody, and now nothing in the app can spell
    /// it: `OpenWorkspaceNotification` keeps the name to itself, so this test is the only caller
    /// left in the tree that can write the string at all.
    @Test("a bare string posted down the same channel is not mistaken for an id")
    func aStringIsNotAnIdentifier() {
        let centre = NotificationCenter()
        let received = Received()

        let subscription = OpenWorkspaceNotification.publisher(on: centre)
            .sink { received.ids.append($0) }
        centre.post(name: Notification.Name("bloomOpenWorkspace"), object: "w1")
        OpenWorkspaceNotification.post(WorkspaceID("w2"), on: centre)
        subscription.cancel()

        #expect(received.ids == [WorkspaceID("w2")])
    }

    /// A collector rather than a captured `var`, because a Combine sink escapes and a test is not
    /// isolated to anything.
    private final class Received {
        var ids: [WorkspaceID] = []
    }
}
