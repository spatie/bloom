import Foundation
import Testing
@testable import BloomClient

@Suite struct ServerSetupVersionComparisonTests {
    private let installedDigest = String(repeating: "a", count: 64)
    private let includedDigest = String(repeating: "b", count: 64)

    private func compare(_ installed: String?, _ included: String?, installedHash: String? = nil,
                         includedHash: String? = nil, managed: Bool? = nil) -> ServerSetupVersionComparison {
        ServerSetupVersionComparison(
            installedVersion: installed, installedPackageSHA256: installedHash,
            included: ServerSetupPackageMetadata(sha256: includedHash ?? includedDigest, protocolVersion: 14,
                                                version: included, maintenanceProtocolVersion: 1),
            maintenanceManagement: managed)
    }

    @Test func packageIdentityIsStrongerThanVersionLabels() {
        let result = compare(nil, "1.2.3", installedHash: installedDigest, includedHash: installedDigest.uppercased())
        #expect(result.state == .sameBuild)
        #expect(result.installedLabel == "Build aaaaaaaaaaaa")
        #expect(compare("v1.2.3", "1.2.3").state == .sameVersion)
    }

    @Test func stableVersionsCanBeOrderedNumerically() {
        #expect(compare("1.9.0", "1.10.0").state == .updateAvailable)
        #expect(compare("2.0.0", "1.10.0").state == .installedNewer)
        #expect(compare("1.10.0", "1.10.0").state == .sameVersion)
    }

    @Test func developmentIdentitiesAndPrereleasesAreNotClaimedAsNewer() {
        #expect(compare("0.0.0-dev.abcdef", "0.0.0-dev.123456").state == .differentDevelopmentBuild)
        #expect(compare("1.0.0-beta.1", "1.0.0-beta.2").state == .unknown)
        #expect(compare("unknown", "1.0.0").state == .unknown)
        #expect(compare(nil, "0.0.0-dev.123456").state == .unknown)
        #expect(compare(nil, "1.0.0").installedLabel == "Unknown")
        #expect(compare(" \n", "1.0.0").installedLabel == "Unknown")
    }

    @Test func currentPackageCanStillNeedSupervisorInstallation() {
        let result = compare("1.2.3", "1.2.3", installedHash: installedDigest,
                             includedHash: installedDigest, managed: false)
        #expect(result.state == .sameBuild)
        #expect(result.needsMaintenanceSetup)
        #expect(!compare("1.2.3", "1.2.3", managed: true).needsMaintenanceSetup)
        #expect(!compare("1.2.3", "1.2.3").needsMaintenanceSetup)
    }

    @Test func absentPackageAndInvalidDigestAreNotUpdateEvidence() {
        let result = ServerSetupVersionComparison(installedVersion: "1.2.3", installedPackageSHA256: "invalid",
                                                 included: nil, maintenanceManagement: false)
        #expect(result.state == .packageUnavailable)
        #expect(result.includedLabel == "Unavailable")
        #expect(compare(nil, nil, installedHash: "invalid").installedLabel == "Unknown")
    }

    @Test func legacyPackageMetadataDecodesWithoutInventedVersion() throws {
        let data = Data(#"{"sha256":"fixture","protocolVersion":14}"#.utf8)
        let value = try JSONDecoder().decode(ServerSetupPackageMetadata.self, from: data)
        #expect(value.version == nil)
        #expect(value.maintenanceProtocolVersion == nil)
        #expect(try JSONDecoder().decode(ServerSetupPackageMetadata.self, from: JSONEncoder().encode(value)) == value)
    }
}
