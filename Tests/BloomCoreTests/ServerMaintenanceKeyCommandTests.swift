import Testing
@testable import BloomCore

@Suite("Maintenance key replacement command")
struct ServerMaintenanceKeyCommandTests {
    @Test func onlyTheDigestCrossesTheAdministratorConnection() throws {
        let digest = String(repeating: "ab", count: 32)
        let command = try ServerSetupConnection.replaceMaintenanceKeyCommand(digest: digest)
        #expect(command.contains("--replace-maintenance-key --maintenance-key-sha256 '\(digest)'"))
        #expect(command.contains("sudo -n python3 -"))
    }

    @Test func anythingButALowercaseDigestIsRefusedBeforeSSH() {
        for value in ["", "raw-maintenance-key", String(repeating: "AB", count: 32),
                      String(repeating: "a", count: 63), String(repeating: "a", count: 64) + "'; reboot"] {
            #expect(throws: ServerFailure.self) { try ServerSetupConnection.replaceMaintenanceKeyCommand(digest: value) }
        }
    }
}
