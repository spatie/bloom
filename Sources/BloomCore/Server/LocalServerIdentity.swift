import Foundation

/// Development and release apps must never register the same launch agent or open the same
/// server database. The child receives the application ID, rather than an expanded home path.
public struct LocalServerIdentity: Sendable, Equatable {
    public static let plistName = "BloomServer.plist"
    public let bundleID: String
    public var serviceLabel: String { bundleID + ".local-server" }

    public init(bundleID: String) throws {
        let normalised = bundleID.lowercased()
        let components = normalised.split(separator: ".", omittingEmptySubsequences: false)
        guard normalised.utf8.count <= 200, components.count >= 2,
              components.allSatisfy({ !$0.isEmpty }),
              normalised.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw ServerFailure("The application identifier is not valid for a local server.")
        }
        self.bundleID = normalised
    }

    public func directory(in support: URL = supportDirectory) -> String {
        support.appendingPathComponent("Bloom Servers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true).path
    }

    public static var supportDirectory: URL {
        if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return directory
        }
        #if os(Linux)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        #endif
    }
}
