import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerSetupTests {
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
        #expect(arguments.contains("UserKnownHostsFile=\"/tmp/Bloom Remote/known_hosts\""))
    }

    @Test(arguments: ["relative/key", "~/key", "/tmp/key\nother", "/tmp/key\u{0}", "/tmp/%h", "/tmp/${HOME}/key"])
    func rejectsPathsWithSSHExpansionOrControlCharacters(path: String) {
        #expect(throws: ServerSetupFailure(code: .invalidAddress)) {
            try ServerSetupSSH.validateIdentityFile(path)
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
}
