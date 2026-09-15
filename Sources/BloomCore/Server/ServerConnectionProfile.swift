import Foundation

/// A saved address and local key references, never the contents of a key or an access token.
public struct ServerConnectionProfile: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public let usesHTTPS: Bool
    public let httpsAddress: String
    public let host: String
    public let executable: String
    public let directory: String
    public let identityFile: String
    public let knownHostsFile: String

    public init?(values: [String: String], label: String = "") {
        usesHTTPS = values["usesHTTPS"] == "true"
        httpsAddress = values["httpsAddress"] ?? ""
        host = values["host"] ?? ""
        executable = values["executable"] ?? ""
        directory = values["directory"] ?? ""
        identityFile = values["identityFile"] ?? ""
        knownHostsFile = values["knownHostsFile"] ?? ""
        self.label = label
        guard usesHTTPS ? !httpsAddress.isEmpty : (!host.isEmpty && !executable.isEmpty && !directory.isEmpty) else { return nil }
    }

    public var endpoint: ServerEndpoint {
        if usesHTTPS { return .https(url: httpsAddress) }
        return .ssh(host: host, executable: executable, directory: directory,
                    identityFile: identityFile.isEmpty ? nil : identityFile,
                    knownHostsFile: knownHostsFile.isEmpty ? nil : knownHostsFile)
    }
    public var id: String { PaneStateNamespace.connectionID(endpoint) }
    public var displayName: String {
        if !label.isEmpty { return label }
        return usesHTTPS ? (URL(string: httpsAddress)?.host ?? httpsAddress) : host
    }

    public static func remembering(_ profile: Self, in profiles: [Self]) -> [Self] {
        var result = profiles.filter { $0.id != profile.id }
        result.append(profile)
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
