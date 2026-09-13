import Foundation

/// Metadata for the exact Linux package included with an app, not a claim about a newer release.
public struct ServerSetupPackageMetadata: Codable, Sendable, Equatable {
    public var sha256: String
    public var protocolVersion: Int
    public var version: String?
    public var maintenanceProtocolVersion: Int?

    public init(sha256: String, protocolVersion: Int, version: String? = nil, maintenanceProtocolVersion: Int? = nil) {
        self.sha256 = sha256; self.protocolVersion = protocolVersion
        self.version = version; self.maintenanceProtocolVersion = maintenanceProtocolVersion
    }
}
