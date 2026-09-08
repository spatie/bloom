import Testing
@testable import BloomCore

struct CrashReportingTests {
    @Test func releasesAndMasterBuildsMayReport() {
        for identity: BuildIdentity in [.release(version: "1.0", build: "1"), .master(commit: "abc123")] {
            #expect(CrashReporting.isEligible(
                bundleIdentifier: "be.spatie.bloom", identity: identity, enabled: true, debuggerAttached: false
            ))
        }
    }

    @Test func localAndOtherBundlesNeverReportAutomatically() {
        #expect(!CrashReporting.isEligible(
            bundleIdentifier: "be.spatie.bloom", identity: .local, enabled: true, debuggerAttached: false
        ))
        for identifier in [nil, "be.spatie.bloom.dev", CrashReporting.probeBundleIdentifier] {
            #expect(!CrashReporting.isEligible(
                bundleIdentifier: identifier, identity: .release(version: "1", build: "1"),
                enabled: true, debuggerAttached: false
            ))
        }
    }

    @Test func preferenceAndDebuggerDisableReporting() {
        #expect(!CrashReporting.isEligible(
            bundleIdentifier: "be.spatie.bloom", identity: .master(commit: "abc"),
            enabled: false, debuggerAttached: false
        ))
        #expect(!CrashReporting.isEligible(
            bundleIdentifier: "be.spatie.bloom", identity: .master(commit: "abc"),
            enabled: true, debuggerAttached: true
        ))
    }

    @Test func environmentsSeparateReleaseMasterAndTestReports() {
        #expect(CrashReporting.environment(for: .release(version: "1", build: "1")) == "production")
        #expect(CrashReporting.environment(for: .master(commit: "abc")) == "development")
        #expect(CrashReporting.environment(for: .local) == "testing")
    }
}
