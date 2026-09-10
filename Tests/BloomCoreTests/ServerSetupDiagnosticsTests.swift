import Foundation
import Testing
@testable import BloomCore

struct ServerSetupDiagnosticsTests {
    @Test func credentialsAndTerminalControlAreRemovedButUsefulErrorsRemain() {
        let source = "\u{1B}[31mapt-get failed: /var/lib/dpkg/lock\u{1B}[0m\nCLIENT_SECRET=\"a short secret\" TOKEN='other value'\nAuthorization: Bearer hide-this\nhttps://user:pass@mirror.example/packages?code=private\nghp_shortsecret\n" + String(repeating: "q", count: 64)
        let value = ServerSetupDiagnostics.sanitise(source)
        #expect(value.contains("apt-get failed: /var/lib/dpkg/lock"))
        for secret in ["a short secret", "other value", "hide-this", "user:pass", "code=private", "ghp_shortsecret", String(repeating: "q", count: 64), "\u{1B}"] {
            #expect(!value.contains(secret))
        }
    }

    @Test func privateKeyBlocksStayHiddenAcrossStreamLinesAndOutputIsBounded() {
        var sanitiser = ServerSetupOutputSanitiser()
        let header = sanitiser.line("-----BEGIN OPENSSH PRIVATE KEY-----")
        let body = sanitiser.line("short-secret-body")
        let ending = sanitiser.line("-----END OPENSSH PRIVATE KEY-----")
        let next = sanitiser.line("dpkg failed with status 1")
        #expect(header == "<redacted private key>")
        #expect(body == nil && ending == nil)
        #expect(next == "dpkg failed with status 1")
        let huge = ServerSetupDiagnostics.sanitise(String(repeating: "output ", count: 10_000), limit: 100)
        #expect(huge.utf8.count < 120)
    }

    @Test func exactInstallerFailureRetainsSafeDetailsAlongsideKnownClassification() {
        let failure = ServerSetupFailure.installation(code: "service_failed", message: "systemctl failed to start Bloom",
            recovery: "Inspect the service journal", details: "Unit file was missing. token=private-value", command: "systemctl start", exitStatus: 5)
        #expect(ServerSetupFailure.installation(code: "command_timeout").code == .timedOut)
        #expect(ServerSetupFailure.installation(code: "cancelled").code == .cancelled)
        #expect(failure.code == .serviceFailed)
        #expect(failure.message == "systemctl failed to start Bloom")
        #expect(failure.recovery == "Inspect the service journal")
        #expect(failure.command == "systemctl start" && failure.exitStatus == 5)
        #expect(failure.details?.contains("Unit file was missing") == true)
        #expect(failure.details?.contains("private-value") == false)
    }
}
