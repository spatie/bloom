import Foundation

/// What the app looked like at the moment something happened.
///
/// Two facts, because two is all it takes: whether Bloom is the app in front of the user, and
/// which workspace that window is showing. Both are read at the instant the event arrives rather
/// than remembered, since a turn that takes four minutes says nothing about where the user is now.
public struct NotificationContext: Sendable, Hashable {
    public var isAppActive: Bool
    public var selectedWorkspaceID: String?

    public init(isAppActive: Bool, selectedWorkspaceID: String?) {
        self.isAppActive = isAppActive
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}

/// Why a notification was or was not sent. An enum rather than a `Bool` so a suppression can be
/// told apart from a switch somebody turned off, which is the difference between a bug and a
/// preference when somebody reports that Bloom went quiet.
public enum NotificationVerdict: Sendable, Hashable {
    case deliver
    case notificationsAreOff
    case eventIsOff
    case alreadyOnScreen

    public var delivers: Bool { self == .deliver }
}

/// The one rule that decides whether to interrupt somebody.
///
/// It lives here, in a type with no AppKit and no `UserNotifications` in sight, precisely because
/// it is the part worth testing: the delivery underneath it is four lines of framework call, and
/// the judgement about when to stay quiet is the whole feature.
public enum NotificationPolicy {
    public static func verdict(
        for event: NotificationEvent,
        workspaceID: String,
        settings: NotificationSettings,
        context: NotificationContext
    ) -> NotificationVerdict {
        guard settings.isEnabled else { return .notificationsAreOff }
        guard settings.enabledEvents.contains(event) else { return .eventIsOff }

        // The user is looking straight at it. A banner over the window that just changed is a
        // banner about something the user watched happen, and it covers the thing it is announcing.
        // Frontmost alone is not enough: with six workspaces open, five of them are off screen
        // while Bloom is the active app, and those are exactly the ones worth saying something
        // about.
        if context.isAppActive, context.selectedWorkspaceID == workspaceID {
            return .alreadyOnScreen
        }

        return .deliver
    }
}
