import AppKit
import BloomAuthentication

/// The one place a maintenance key is read out of the Keychain for another device.
///
/// Setup's Finish step and Maintenance Access both offer it, and a key copied from either must be
/// handled the same way: marked concealed so clipboard managers skip it, and cleared after a
/// minute if nothing else has been copied since.
@MainActor
enum ServerMaintenanceKeyClipboard {
    /// False when this Mac holds no key for the server.
    static func copy(serverID: String) throws -> Bool {
        guard let token = try ServerMaintenanceCredentials.load(serverID: serverID) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
        return true
    }
}
