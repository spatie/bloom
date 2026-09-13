import Testing
@testable import BloomCore

@Suite("Server administration outcomes")
struct ServerAdministrationOutcomeTests {
    @Test func installedWithoutConnectionIsNotSuccess() {
        let result = ServerAdministrationOutcome.resolve(updating: true, installed: true, running: true, connected: false, failed: false)
        #expect(result == .updatedNeedsConnection)
        #expect(!result.succeeded)
    }

    @Test func restoredServiceDoesNotTurnFailedUpdateIntoSuccess() {
        let result = ServerAdministrationOutcome.resolve(updating: true, installed: false, running: true, connected: true, failed: true)
        #expect(result == .updateFailedServerRunning)
        #expect(!result.succeeded)
    }

    @Test func connectionAloneDoesNotProveAnUpdate() {
        let result = ServerAdministrationOutcome.resolve(updating: true, installed: false, running: true, connected: true, failed: false)
        #expect(!result.succeeded)
    }

    @Test func verifiedUpdateIsSuccessful() {
        #expect(ServerAdministrationOutcome.resolve(updating: true, installed: true, running: true, connected: true, failed: false) == .updated)
    }

    @Test func startNeedsNoInstallation() {
        #expect(ServerAdministrationOutcome.resolve(updating: false, installed: false, running: true, connected: true, failed: false) == .started)
    }
}
