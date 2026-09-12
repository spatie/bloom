import Foundation
import Security
import CryptoKit
import BloomClient

/// Maintenance credentials are independent of workspace and SSH access. Each app identity keeps
/// its own non-synchronising, device-only credential for a verified server connection.
public enum ServerMaintenanceCredentials {
    public static func save(token: String, serverID: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...4_096).contains(token.utf8.count), !token.contains(where: \.isWhitespace) else {
            throw ConnectionFailure("Enter the maintenance key provided when this server was set up.")
        }
        let query = try Self.query(serverID: serverID)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure("save", status: status) }
    }

    public static func load(serverID: String) throws -> String? {
        var query = try Self.query(serverID: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw failure("read", status: status)
        }
        return token
    }

    public static func delete(serverID: String) throws {
        let status = SecItemDelete(try Self.query(serverID: serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("remove", status: status) }
    }

    private static func query(serverID: String) throws -> [String: Any] {
        guard !serverID.isEmpty else { throw ConnectionFailure("Connect to a server before adding maintenance access.") }
        let account = SHA256.hash(data: Data(serverID.utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "be.spatie.bloom.dev") + ".server-maintenance",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(iOS)
        return query.merging([kSecUseDataProtectionKeychain as String: true]) { _, new in new }
        #else
        // Match server sign-in storage on macOS. The isolated ad-hoc Remote build has no
        // application-identifier entitlement for the Data Protection Keychain.
        return query
        #endif
    }

    private static func failure(_ action: String, status: OSStatus) -> ConnectionFailure {
        ConnectionFailure("Could not \(action) maintenance access in Keychain. Unlock this device and try again (Keychain \(status)).")
    }
}
