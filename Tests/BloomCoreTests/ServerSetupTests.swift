import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerSetupTests {
    @Test func setupDeadlineIncludesBlockedInstallerInputAndExplainsSSHApproval() async throws {
        do {
            _ = try await ServerSetupConnection.commandOutput("/bin/sh", arguments: ["-c", "exec sleep 30"],
                input: String(repeating: "x", count: 1_048_576), timeout: .milliseconds(100))
            Issue.record("A command that never reads its input should time out")
        } catch let failure as ServerSetupFailure {
            #expect(failure.code == .timedOut)
            #expect(failure.recovery.contains("1Password"))
            #expect(failure.recovery.contains("Check Again"))
            #expect(failure.command == "ssh")
            #expect(failure.exitStatus == nil)
        }
    }

    @Test func ordinaryExitFifteenIsNotAssumedToBeADeadline() async throws {
        let result = try await ServerSetupConnection.commandOutput("/bin/sh", arguments: ["-c", "exit 15"], input: "", timeout: .seconds(5))
        #expect(result.status == 15)
        let failure = ServerSetupFailure.classify(status: result.status, stderr: "", command: "ssh")
        #expect(failure.code != .timedOut)
    }

    @Test func cancellingSetupRetainsCancellationInsteadOfShowingTimeout() async throws {
        let task = Task {
            try await ServerSetupConnection.commandOutput("/bin/sh", arguments: ["-c", "exec sleep 30"],
                input: String(repeating: "x", count: 1_048_576), timeout: .seconds(5))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled setup should not complete")
        } catch is CancellationError { /* User cancellation is distinct from a timeout. */ }
    }

    @Test func stoppedServerReturnsUnrelatedFreshBlockers() throws {
        let check = try ServerSetupConnection.stoppedServerCheck(status: 0, output: stopCheck(code: "disk_full"))
        #expect(check.existing)
        #expect(check.blockers.map(\.code) == ["disk_full"])
    }

    @Test(arguments: ["server_running", "server_busy", "installation_busy"])
    func stoppedServerRejectsConcurrentRestartOrWork(code: String) {
        #expect(throws: ServerSetupFailure.self) {
            try ServerSetupConnection.stoppedServerCheck(status: 0, output: stopCheck(code: code))
        }
    }

    @Test func failedStopPreservesExactSafeDiagnostic() throws {
        let output = #"{"event":"error","code":"command_failed","message":"systemd refused the stop","recovery":"Inspect the managed unit","command":"systemctl stop bloom-server.service","exitStatus":5,"details":"token=secret-fixture"}"#
        do {
            _ = try ServerSetupConnection.stoppedServerCheck(status: 1, output: output)
            Issue.record("A failed stop was accepted")
        } catch let failure as ServerSetupFailure {
            #expect(failure.message == "systemd refused the stop")
            #expect(failure.recovery == "Inspect the managed unit")
            #expect(failure.command == "systemctl stop bloom-server.service")
            #expect(failure.exitStatus == 5)
            #expect(failure.details?.contains("secret-fixture") == false)
        }
    }

    @Test func stoppedServerRequiresSuccessfulCompleteCheck() {
        for output in ["", "{}", "not JSON", #"{"event":"complete"}"#] {
            #expect(throws: ServerSetupFailure.self) {
                try ServerSetupConnection.stoppedServerCheck(status: 0, output: output)
            }
        }
        #expect(throws: ServerSetupFailure.self) {
            try ServerSetupConnection.stoppedServerCheck(status: 1, output: stopCheck(code: "disk_full"))
        }
    }

    @Test func stopCommandUsesExplicitNoninteractiveAdministratorMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-stop-wrapper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeID = directory.appendingPathComponent("id")
        try Data("#!/bin/sh\nprintf '0\\n'\n".utf8).write(to: fakeID)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeID.path)
        let result = try await Shell.run("/bin/sh", ["-c", ServerSetupConnection.stopServerCommand],
            env: ["PATH": directory.path + ":/usr/bin:/bin"],
            stdin: "import sys\nprint(sys.argv[1])\n", timeout: .seconds(5))
        #expect(result.ok)
        #expect(result.trimmed == "--stop-server")
        #expect(ServerSetupConnection.stopServerCommand.contains("sudo -n python3 - --stop-server"))
    }

    private func stopCheck(code: String) -> String {
        #"{"event":"check","platform":"ubuntu","architecture":"x86_64","privilege":"root","existing":true,"blockers":[{"code":"\#(code)","message":"Fresh status"}],"warnings":[],"executable":"/home/bloom/bloom/server/current/bin/bloom-server","dataDirectory":"/home/bloom/bloom/data","serviceUser":"bloom"}"#
    }

    @Test(arguments: ["", ", \"recovery\": null"])
    func legacyInstallerNoticesDecodeWithSafeRecoveryFallback(recoveryField: String) throws {
        let json = "{\"code\":\"installation_conflict\",\"message\":\"The installation needs attention.\"\(recoveryField)}"
        let notice = try JSONDecoder().decode(ServerInstallNotice.self, from: Data(json.utf8))
        #expect(notice.message == "The installation needs attention.")
        #expect(notice.recovery == nil)
        #expect(notice.recoverySuggestion == ServerSetupFailure(code: .accountConflict).recovery)
    }

    @Test func installerNoticePreservesExplicitRecoveryThroughCoding() throws {
        let json = #"{"code":"service_account_exists","message":"The account existing-bloom exists.","recovery":"Ask the administrator to inspect existing-bloom before changing it."}"#
        let notice = try JSONDecoder().decode(ServerInstallNotice.self, from: Data(json.utf8))
        let expected = "Ask the administrator to inspect existing-bloom before changing it."
        #expect(notice.recovery == expected)
        #expect(notice.recoverySuggestion == expected)
        let roundTrip = try JSONDecoder().decode(ServerInstallNotice.self, from: JSONEncoder().encode(notice))
        #expect(roundTrip == notice)
    }

    @Test func unmanagedServiceAccountHasDistinctRecoveryFromInstallationConflicts() throws {
        let notice = try JSONDecoder().decode(ServerInstallNotice.self,
            from: Data(#"{"code":"service_account_exists","message":"The bloom account exists."}"#.utf8))
        let failure = ServerSetupFailure.installation(code: notice.code)
        #expect(failure.code == .serviceAccountExists)
        #expect(failure.code != ServerSetupFailure.installation(code: "installation_conflict").code)
        #expect(notice.recoverySuggestion == failure.recovery)
        #expect(failure.message.contains("will not take over"))
        #expect(failure.recovery.contains("advanced settings"))
        #expect(failure.recovery.contains("inspect its files and processes"))
        #expect(failure.recovery.contains("back up"))
        #expect(failure.recovery.contains("unused account"))
        #expect(failure.recovery.contains("fresh server"))
    }

    @Test(arguments: ["browser", "docker", "swap"]) func optionalInstallersTreatPathsAsArguments(installer: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-browser-wrapper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Exercise the root branch without obtaining privileges or installing anything.
        let fakeID = directory.appendingPathComponent("id")
        try Data("#!/bin/sh\nprintf '0\\n'\n".utf8).write(to: fakeID)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeID.path)
        let home = "/var/lib/Bloom user's $(printf ignored)"
        let source = "import json,sys\nprint(json.dumps({'source': '__bloom_browser_source' in globals(), 'arguments': sys.argv[1:]}))\n"
        let command = switch installer {
        case "browser": try ServerSetupConnection.browserInstallerCommand(user: "bloom", serviceHome: home)
        case "swap": try ServerSetupConnection.swapInstallerCommand(user: "bloom", serviceHome: home)
        default: try ServerSetupConnection.dockerInstallerCommand(user: "bloom", serviceHome: home)
        }
        let result = try await Shell.run("/bin/sh", ["-c", command], env: ["PATH": directory.path + ":/usr/bin:/bin"], stdin: source, timeout: .seconds(5))
        #expect(result.ok)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        #expect(decoded["source"] == .bool(installer == "browser"))
        #expect(decoded["arguments"] == .array([.string("--user"), .string("bloom"), .string("--service-home"), .string(home)]))
    }

    @Test func browserSetupRejectsInvalidServiceIdentityAndDecodesOptionalResult() throws {
        for user in ["root;command", "-option", "name\nother"] {
            #expect(throws: ServerSetupFailure.self) { try ServerSetupConnection.browserInstallerCommand(user: user, serviceHome: "/var/lib/bloom-home") }
            #expect(throws: ServerSetupFailure.self) { try ServerSetupConnection.dockerInstallerCommand(user: user, serviceHome: "/home/bloom") }
            #expect(throws: ServerSetupFailure.self) { try ServerSetupConnection.swapInstallerCommand(user: user, serviceHome: "/home/bloom") }
        }
        #expect(throws: ServerSetupFailure.self) { try ServerSetupConnection.browserInstallerCommand(user: "bloom", serviceHome: "relative") }
        let installed = try JSONDecoder().decode(ServerInstallEvent.self, from: Data(#"{"event":"complete","serviceUser":"bloom","serviceHome":"/var/lib/bloom-home"}"#.utf8))
        #expect(installed.serviceHome == "/var/lib/bloom-home")
        let browser = try JSONDecoder().decode(ServerInstallEvent.self, from: Data(#"{"event":"error","ready":false,"code":"container_unsupported","message":"Host only","recovery":"Connect to a host"}"#.utf8))
        #expect(browser.ready == false && browser.code == "container_unsupported")
        #expect(browser.message == "Host only" && browser.recovery == "Connect to a host")
    }

    @Test(arguments: ["my-server", "bloom@my-server", "root@94.237.125.23", "remote.example.org", "server_alias", "bloom@[2001:db8::1]"])
    func acceptsHostsAndSSHConfigurationAliases(destination: String) throws {
        #expect(try ServerSetupSSH.validateDestination(destination) == destination)
    }

    @Test(arguments: ["", "-oProxyCommand=evil", "user@-host", "@host", "user@", "a@b@c", "user name@host", "host\nother", "host;touch", "$(whoami)", "host`whoami`", "ssh://host", "host:2222", "host/path", "host?query", "host#fragment", "host\u{0}", "host\\name", "[::1];evil", "[host]"])
    func rejectsCommandFragmentsAndAmbiguousAddresses(destination: String) {
        #expect(throws: ServerSetupFailure(code: .invalidAddress)) {
            try ServerSetupSSH.validateDestination(destination)
        }
    }

    @Test func keyPathsRemainSingleArgumentsWithoutShellInterpolation() throws {
        let identity = "/tmp/SSH Keys/freek's $(key);`literal`"
        #expect(try ServerSetupSSH.validateIdentityFile(identity) == identity)
        let arguments = try ServerSetupSSH.arguments(destination: "bloom@production-alias", knownHostsFile: "/tmp/Bloom Remote/known_hosts", identityFile: identity, command: "true")
        let keyIndex = try #require(arguments.firstIndex(of: "-i"))
        #expect(arguments[keyIndex + 1] == identity)
        #expect(arguments.suffix(3) == ["--", "bloom@production-alias", "true"])
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("IdentityAgent=none"))
        #expect(arguments.contains("UserKnownHostsFile=\"/tmp/Bloom Remote/known_hosts\""))
    }

    @Test(arguments: ["relative/key", "~/key", "/tmp/key\nother", "/tmp/key\u{0}", "/tmp/%h", "/tmp/${HOME}/key"])
    func rejectsPathsWithSSHExpansionOrControlCharacters(path: String) {
        #expect(throws: ServerSetupFailure(code: .invalidAddress)) {
            try ServerSetupSSH.validateIdentityFile(path)
        }
    }

    @Test func absentOrEmptyKeyPreservesConfiguredAgentAuthentication() throws {
        for identity: String? in [nil, ""] {
            let arguments = try ServerSetupSSH.arguments(destination: "production", knownHostsFile: "/tmp/known_hosts", identityFile: identity, command: "true")
            #expect(!arguments.contains(where: { $0.hasPrefix("IdentityAgent=") }))
            #expect(!arguments.contains("IdentitiesOnly=yes"))
            #expect(!arguments.contains("-i"))
        }
    }

    @Test func trustsOnlyPinnedKeysAndDoesNotReuseMasterConnections() throws {
        let arguments = try ServerSetupSSH.arguments(destination: "production", knownHostsFile: "/tmp/a \"quoted\" \\path/known_hosts", command: "true")
        for option in ["StrictHostKeyChecking=yes", "UpdateHostKeys=no", "GlobalKnownHostsFile=/dev/null", "ControlMaster=no", "ControlPath=none", "BatchMode=yes", "ForwardAgent=no", "PermitLocalCommand=no", "ClearAllForwardings=yes"] {
            #expect(arguments.contains(option))
        }
        #expect(arguments.contains("UserKnownHostsFile=\"/tmp/a \\\"quoted\\\" \\\\path/known_hosts\""))
        #expect(!arguments.contains("IdentitiesOnly=yes"))
        #expect(!arguments.contains("-i"))
        #expect(try ServerSetupSSH.validateIdentityFile("") == nil)
        #expect(throws: ServerSetupFailure(code: .invalidAddress)) {
            try ServerSetupSSH.arguments(destination: "production", knownHostsFile: "", command: "true")
        }
    }

    @Test func trustedKeyLookupHandlesHashedHostsCommentsAndRevocation() {
        let candidate = "example.org ssh-ed25519 AQID\n"
        let known = "# Host example.org found: line 2\n|1|hash|hash ssh-ed25519 AQID a user comment\n"
        #expect(ServerSetupSSH.trustMatches(lookupOutput: known, candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: "example.org ssh-ed25519 BAUG", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: "example.org ssh-rsa AQID", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: "@cert-authority *.org ssh-ed25519 AQID", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: known + "@revoked example.org ssh-ed25519 AQID revoked by administrator", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: "@revoked example.org ssh-ed25519 AQID\n" + known, candidateLine: candidate))
        #expect(ServerSetupSSH.trustMatches(lookupOutput: known + "@revoked example.org ssh-ed25519 BAUG", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: "# only a comment\ninvalid", candidateLine: candidate))
        #expect(!ServerSetupSSH.trustMatches(lookupOutput: known, candidateLine: ""))
    }

    @Test func shellQuotingPreservesMetacharactersAsData() {
        #expect(ServerSetupSSH.shellQuote("") == "''")
        #expect(ServerSetupSSH.shellQuote("a'b") == "'a'\\''b'")
        #expect(ServerSetupSSH.shellQuote("$(id);\n`id` \\") == "'$(id);\n`id` \\'")
    }

    @Test(arguments: [
        ("REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.", ServerSetupFailure.Code.hostChanged),
        ("Offending ED25519 host key in /secret/path", .hostChanged),
        ("WARNING: REVOKED HOST KEY DETECTED! Host key verification failed.", .hostChanged),
        ("No ED25519 host key is known for host and you have requested strict checking.\nHost key verification failed.", .hostUnknown),
        ("No ED25519 host key is known for host and you have requested strict checking.", .hostUnknown),
        ("Permission denied (publickey).", .authentication),
        ("Permission denied (publickey,password,keyboard-interactive).", .authentication),
        ("WARNING: UNPROTECTED PRIVATE KEY FILE!", .authentication),
        ("sign_and_send_pubkey: signing failed: communication with agent failed", .authentication),
        ("Load key /secret/path: incorrect passphrase supplied to decrypt private key", .authentication),
        ("Could not resolve hostname private.internal", .unreachable),
        ("ssh: connect to host example port 22: Operation timed out", .unreachable),
        ("client_loop: send disconnect: Broken pipe", .unreachable),
        ("sudo: a password is required", .permission),
        ("mkdir: cannot create directory: Permission denied", .permission),
        ("No space left on device", .diskSpace),
    ])
    func failuresHaveSpecificRecovery(output: String, expected: ServerSetupFailure.Code) {
        let failure = ServerSetupFailure.classify(status: 255, stderr: output)
        #expect(failure.code == expected)
        #expect(!failure.title.isEmpty)
        #expect(!failure.recovery.isEmpty)
    }

    @Test(arguments: [
        ("server_running", ServerSetupFailure.Code.serverRunning),
        ("server_busy", .busy), ("installation_busy", .busy),
        ("disk_full", .diskSpace), ("disk_space", .diskSpace),
        ("checksum_mismatch", .packageInvalid), ("unsafe_package", .packageInvalid),
        ("unsupported_architecture", .unsupported), ("systemd_required", .unsupported),
        ("installation_conflict", .accountConflict), ("untrusted_keys", .accountConflict),
        ("service_account_exists", .serviceAccountExists),
        ("startup_failed", .serviceFailed), ("administrator_required", .permission),
        ("package_required", .packageMissing), ("unknown_remote_secret", .installation),
    ])
    func installerCodesProduceSafeActionableFailures(code: String, expected: ServerSetupFailure.Code) {
        let failure = ServerSetupFailure.installation(code: code)
        #expect(failure.code == expected)
        #expect(!failure.message.contains("unknown_remote_secret"))
        if code == "server_running" {
            #expect(failure.recovery.contains("stop Bloom Server"))
        }
    }

    @Test func arbitraryRemoteOutputAndSecretsNeverReachErrorCopy() {
        #expect(ServerSetupFailure.installation(code: "database_backup_failed").code == .backupFailed)
        let secret = "ghp_this_is_a_secret"
        for code in ServerSetupFailure.Code.allCases {
            let failure = ServerSetupFailure(code: code)
            #expect(!failure.message.isEmpty)
            #expect(failure.errorDescription == failure.message)
            #expect(failure.recoverySuggestion == failure.recovery)
        }
        for output in [secret, "Permission denied (publickey). token=\(secret)", "\u{1B}[31m\(secret)", "sudo: \(secret)"] {
            let failure = ServerSetupFailure.classify(status: 1, stderr: output)
            #expect(!"\(failure.title) \(failure.message) \(failure.recovery)".contains(secret))
        }
        #expect(ServerSetupFailure.classify(status: 255, stderr: "").code == .unreachable)
        #expect(ServerSetupFailure.classify(status: 1, stderr: "").code == .unknown)
    }
    @Test func swapIsOfferedOnlyAfterAnExplicitCheckFindsNone() throws {
        let data = Data(#"{"platform":"Ubuntu 26.04","architecture":"x86_64","privilege":"root","existing":false,"blockers":[],"warnings":[],"executable":"/home/bloom/bloom/runtime/current/bin/bloom-server","dataDirectory":"/home/bloom/bloom/data","serviceUser":"bloom"}"#.utf8)
        let legacy = try JSONDecoder().decode(ServerInstallCheck.self, from: data)
        #expect(legacy.memoryBytes == nil && legacy.activeSwapBytes == nil && legacy.configuredSwap == nil)
        #expect(!legacy.shouldOfferSwapInstall)
        for (active, configured, offered) in [(Int64(0), false, true), (Int64(0), true, false), (Int64(2_147_483_648), false, false), (Int64(2_147_483_648), true, false)] {
            var check = legacy
            check.memoryBytes = 1_073_741_824
            check.activeSwapBytes = active
            check.configuredSwap = configured
            let decoded = try JSONDecoder().decode(ServerInstallCheck.self, from: JSONEncoder().encode(check))
            #expect(decoded.shouldOfferSwapInstall == offered)
            #expect(decoded.memoryBytes == check.memoryBytes)
            #expect(decoded.activeSwapBytes == active)
            #expect(decoded.configuredSwap == configured)
        }
        var unknown = legacy
        unknown.activeSwapBytes = 0
        #expect(!unknown.shouldOfferSwapInstall)
        unknown.activeSwapBytes = nil
        unknown.configuredSwap = false
        #expect(!unknown.shouldOfferSwapInstall)
    }

    @Test func installationLocationsComeFromPreflight() throws {
        let data = Data(#"{"platform":"Ubuntu 26.04","architecture":"x86_64","privilege":"root","existing":false,"blockers":[],"warnings":[],"executable":"/opt/custom/current/bin/bloom-server","dataDirectory":"/var/lib/custom-data","serviceUser":"custom","installationRoot":"/opt/custom","serviceHome":"/var/lib/custom-home"}"#.utf8)
        let check = try JSONDecoder().decode(ServerInstallCheck.self, from: data)
        #expect(check.installationRoot == "/opt/custom")
        #expect(check.serviceHome == "/var/lib/custom-home")
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "installationRoot")
        legacy.removeValue(forKey: "serviceHome")
        let legacyCheck = try JSONDecoder().decode(ServerInstallCheck.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(legacyCheck.installationRoot == nil)
        #expect(legacyCheck.serviceHome == nil)
    }

}
