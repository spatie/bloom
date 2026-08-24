import Foundation

/// What a banner carries about the workspace it is about, and the one place it is written and read.
///
/// `UNNotificationContent.userInfo` is `[AnyHashable: Any]`, and the notification is handed to a
/// system daemon over XPC, so every value in it has to be a property list type. Putting a
/// `WorkspaceID` in there compiles, and then `-[NSXPCEncoder _checkObject:]` raises
/// `NSInvalidArgumentException` on `__SwiftValue` inside `UNUserNotificationCenter.add`, which is
/// an uncaught Objective-C exception and therefore not an error the completion handler reports:
/// the app is gone. Measured, on the first banner an agent finishing would have produced. The read
/// side was broken too, casting the same struct back `as? String`, so even a banner that had
/// survived would have opened nothing.
///
/// Hence a `[String: String]` on the way out. The type is the guarantee: a dictionary that cannot
/// hold anything but strings cannot hold anything the daemon will refuse.
public enum BannerUserInfo {
    /// The bytes of this key are what banners already sitting in Notification Center were written
    /// with, so it is not free to change.
    private static let workspaceKey = "bloomWorkspaceID"

    public static func encode(workspaceID: WorkspaceID) -> [String: String] {
        [workspaceKey: workspaceID.rawValue]
    }

    /// Nil for a banner that names no workspace, which is the test notification sent before
    /// anything has ever been selected, and nil for anything that is not the string this wrote.
    public static func workspaceID(from userInfo: [AnyHashable: Any]) -> WorkspaceID? {
        guard let raw = userInfo[workspaceKey] as? String, !raw.isEmpty else { return nil }
        return WorkspaceID(raw)
    }
}
