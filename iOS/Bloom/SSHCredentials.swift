import Foundation
import Security
import BloomClient
import BloomSSH

/// Device credentials and host pins stay in the device-only, non-synchronising Keychain.
@MainActor
enum SSHCredentials {
    private static let service = "be.spatie.bloom.ios.ssh"
    static func identity() throws -> Data {
        if let key = try read("identity") { return key }
        let key = SSHIdentity.generate()
        try write(key, account: "identity")
        return key
    }
    static func fingerprint(for host: String) throws -> String? {
        try read("host:" + host).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func trust(_ fingerprint: String, host: String) throws {
        try write(Data(fingerprint.utf8), account: "host:" + host)
    }
    static func forgetHost(_ host: String) throws {
        let status = SecItemDelete(query("host:" + host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionFailure("Could not remove saved SSH trust (Keychain \(status)).")
        }
    }
    private static func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecMissingEntitlement {
                throw ConnectionFailure("This app build is missing its Keychain entitlement. Reinstall a signed Bloom build to connect with SSH.")
            }
            throw ConnectionFailure("Could not access SSH credentials. Unlock your device and try again (Keychain \(status)).")
        }
        return data
    }
    private static func write(_ data: Data, account: String) throws {
        let base = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ConnectionFailure("Could not save SSH credentials securely (Keychain \(status)).") }
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
