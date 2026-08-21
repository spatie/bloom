import Foundation
import Testing
@testable import BloomCore

/// What a banner is allowed to carry, and why the type of the dictionary is the whole fix.
///
/// `UNNotificationContent.userInfo` is `[AnyHashable: Any]` and is encoded for XPC on its way to
/// the notification daemon, so a value that is not a property list type is not a value that fails
/// to arrive: it is an `NSInvalidArgumentException` out of `NSXPCEncoder` inside
/// `UNUserNotificationCenter.add`, uncaught, with the app gone. None of that can be reached from
/// here, because `UNUserNotificationCenter.current()` needs a bundle. What can be reached from
/// here is the one thing the daemon checks, which is whether the payload is a property list.
@Suite("Banner userInfo")
struct BannerUserInfoTests {
    @Test("what a banner carries is a property list, which is the only kind of value it may carry")
    func encodesAPropertyList() {
        let userInfo = BannerUserInfo.encode(workspaceID: WorkspaceID("w1"))
        #expect(PropertyListSerialization.propertyList(userInfo, isValidFor: .binary))
    }

    /// The bug this file was written for. A `WorkspaceID` is a struct, so it crosses into
    /// `[AnyHashable: Any]` as an opaque `__SwiftValue`: not a property list, and not a `String`
    /// on the way back either, so the click that survived would have opened nothing.
    @Test("the struct that used to be written here is neither a property list nor readable")
    func theOldEncodingWasUnsendableAndUnreadable() {
        let old: [AnyHashable: Any] = ["bloomWorkspaceID": WorkspaceID("w1")]
        #expect(!PropertyListSerialization.propertyList(old, isValidFor: .binary))
        #expect(BannerUserInfo.workspaceID(from: old) == nil)
    }

    @Test("an id written into a banner is the id read back out of it")
    func roundTrips() {
        let userInfo = BannerUserInfo.encode(workspaceID: WorkspaceID("9d4b0f1e-1111-2222"))
        #expect(BannerUserInfo.workspaceID(from: userInfo) == WorkspaceID("9d4b0f1e-1111-2222"))
    }

    /// The test notification sent from the settings pane before anything has ever been selected
    /// names no workspace, and clicking it must land on the window rather than on a workspace
    /// whose id is the empty string.
    @Test("a banner that names no workspace reads back as none")
    func namesNoWorkspace() {
        let unnamed = BannerUserInfo.encode(workspaceID: WorkspaceID(""))
        #expect(BannerUserInfo.workspaceID(from: unnamed) == nil)
        #expect(BannerUserInfo.workspaceID(from: [:]) == nil)
        #expect(BannerUserInfo.workspaceID(from: ["somethingElse": "w1"]) == nil)
    }
}
