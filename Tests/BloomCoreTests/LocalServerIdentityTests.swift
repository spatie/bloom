import Foundation
import Testing
@testable import BloomCore

@Suite("LocalServerIdentity")
struct LocalServerIdentityTests {
    @Test func developmentAndReleaseServicesHaveSeparateStorageAndLabels() throws {
        let release = try LocalServerIdentity(bundleID: "be.spatie.bloom")
        let development = try LocalServerIdentity(bundleID: "be.spatie.bloom.dev")
        let support = URL(fileURLWithPath: "/test/Application Support")
        #expect(release.serviceLabel == "be.spatie.bloom.local-server")
        #expect(development.serviceLabel == "be.spatie.bloom.dev.local-server")
        #expect(release.directory(in: support) != development.directory(in: support))
        #expect(development.directory(in: support) == "/test/Application Support/Bloom Servers/be.spatie.bloom.dev")
        #expect(!release.directory(in: support).contains("/Bloom/"))
    }

    @Test(arguments: ["../Bloom", "..", "be..bloom", "be.spatie/bloom", "be.spatie\0bloom", "", "no-dots"])
    func malformedIdentifiersCannotEscapeTheServerDirectory(_ value: String) {
        #expect(throws: ServerFailure.self) { _ = try LocalServerIdentity(bundleID: value) }
    }

    @Test func identifierCaseCannotCreateTwoServicesOnACaseInsensitiveDisk() throws {
        let first = try LocalServerIdentity(bundleID: "be.Spatie.Bloom.Dev")
        let second = try LocalServerIdentity(bundleID: "be.spatie.bloom.dev")
        #expect(first == second)
    }
}
