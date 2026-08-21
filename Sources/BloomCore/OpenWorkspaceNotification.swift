import Combine
import Foundation

/// The channel that says "select this workspace", and the only door into it.
///
/// `NotificationCenter` carries an `Any?`, so `object: workspaceID` and `note.object as? String`
/// both compile and the cast returns nil for ever. That is the failure `Identifier.swift` was
/// written to end, and it came straight back at the first untyped boundary: of the six posters,
/// the banner reply, the Open Workspace intent, the dock menu and the menu bar item were handing
/// over a `WorkspaceID` while the capture flags handed over a `String`, against one reader casting
/// to `String`. Four of the six selected nothing at all, silently, which is the same shape as the
/// bug in `a28461b` without the trap that made that one findable.
///
/// It exists at all so that delivering a notification, running an intent or picking a menu item
/// stays separate from navigating: nothing outside the window owns the selection, it only asks.
///
/// So the name is private and the two ends are here together. Nothing else in the app can name the
/// channel, which means nothing else can encode an id into it or decode one out of it, and the
/// mixed-type post that caused this is no longer something a call site can express. It lives in
/// the core rather than beside a view for the usual reason: this way the round trip has a test.
public enum OpenWorkspaceNotification {
    /// Private, and load bearing. A visible `Notification.Name` is a second encoder: any file that
    /// can name it can post whatever it likes down the channel, which is precisely what happened.
    private static let name = Notification.Name("bloomOpenWorkspace")

    /// The centre is a parameter so a test can post on its own rather than on the one the running
    /// app is listening to.
    public static func post(_ workspaceID: WorkspaceID, on centre: NotificationCenter = .default) {
        centre.post(name: name, object: workspaceID)
    }

    /// Erased on purpose: the concrete `Publishers.CompactMap<NotificationCenter.Publisher, ...>`
    /// would put the channel's name back in a caller's reach through the publisher's own `name`.
    public static func publisher(
        on centre: NotificationCenter = .default
    ) -> AnyPublisher<WorkspaceID, Never> {
        centre.publisher(for: name)
            .compactMap { $0.object as? WorkspaceID }
            .eraseToAnyPublisher()
    }
}
