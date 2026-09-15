import Foundation

/// Commit hashes are identities, not ordered versions. Equal package digests are stronger evidence
/// than labels, and unknown development builds must never be presented as a known upgrade.
public struct ServerSetupVersionComparison: Sendable {
    public enum State: Sendable, Equatable {
        case sameBuild, sameVersion, differentDevelopmentBuild, updateAvailable, installedNewer, unknown, packageUnavailable
    }
    public let state: State
    public let installedLabel: String
    public let includedLabel: String
    public let needsMaintenanceSetup: Bool

    public init(installedVersion: String?, installedPackageSHA256: String?, included: ServerSetupPackageMetadata?,
                maintenanceManagement: Bool?) {
        let installed = Self.normalised(installedVersion)
        let offered = Self.normalised(included?.version)
        let installedHash = Self.digest(installedPackageSHA256)
        let offeredHash = Self.digest(included?.sha256)
        installedLabel = Self.label(installedVersion)
            ?? installedHash.map { "Build " + $0.prefix(12) } ?? "Unknown"
        includedLabel = Self.label(included?.version)
            ?? offeredHash.map { "Build " + $0.prefix(12) } ?? "Unavailable"
        needsMaintenanceSetup = maintenanceManagement == false && included?.maintenanceProtocolVersion == 1
        guard included != nil else { state = .packageUnavailable; return }
        if let installedHash, installedHash == offeredHash { state = .sameBuild; return }
        if let installed, installed == offered { state = .sameVersion; return }
        if installed != nil, offered != nil, installed?.contains("-dev.") == true || offered?.contains("-dev.") == true {
            state = .differentDevelopmentBuild; return
        }
        guard let current = Self.stable(installed), let target = Self.stable(offered) else { state = .unknown; return }
        for (currentPart, targetPart) in zip(current, target) where currentPart != targetPart {
            state = targetPart > currentPart ? .updateAvailable : .installedNewer
            return
        }
        state = .sameVersion
    }

    private static func label(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func normalised(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("v") { value.removeFirst() }
        return value
    }
    private static func digest(_ value: String?) -> String? {
        guard let value = value?.lowercased(), value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    private static func stable(_ value: String?) -> [UInt64]? {
        guard let value else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { UInt64($0) }
        return numbers.count == 3 ? numbers : nil
    }
}
