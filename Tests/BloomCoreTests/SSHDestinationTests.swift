import Testing
import Foundation
@testable import BloomCore

/// What the Add field will take, and what it refuses.
///
/// The refusals are the half worth having. A destination is the one part of a server the user
/// types, it goes into argv for `/usr/bin/ssh`, and the only thing argv cannot defend itself
/// against is a word that looks like an option.
@Suite("SSH destination", .tags(.security))
struct SSHDestinationTests {
    @Test("user@host")
    func userAndHost() throws {
        let destination = try SSHDestination.parse("deploy@vps.example.com")
        #expect(destination.user == "deploy")
        #expect(destination.host == "vps.example.com")
        #expect(destination.port == nil)
        #expect(destination.argument == "deploy@vps.example.com")
    }

    /// The whole point of shelling out to the real client: `Host vps` in `~/.ssh/config` carries
    /// the user, the port, the identity and the jump host, and Bloom has to let it.
    @Test("a bare alias from the user's ssh config is fine")
    func bareAlias() throws {
        let destination = try SSHDestination.parse("vps")
        #expect(destination.user == nil)
        #expect(destination.host == "vps")
        #expect(destination.argument == "vps")
    }

    @Test("a port is taken off the argument and given to -p")
    func port() throws {
        let destination = try SSHDestination.parse("deploy@vps.example.com:2222")
        #expect(destination.port == 2222)
        // `ssh user@host:2222` is read by ssh as a host literally called "host:2222".
        #expect(destination.argument == "deploy@vps.example.com")
        #expect(destination.display == "deploy@vps.example.com:2222")
    }

    @Test("an IPv6 literal keeps its last group")
    func ipv6() throws {
        let plain = try SSHDestination.parse("root@2001:db8::1")
        #expect(plain.host == "2001:db8::1")
        #expect(plain.port == nil)

        let bracketed = try SSHDestination.parse("root@[2001:db8::1]:2222")
        #expect(bracketed.host == "2001:db8::1")
        #expect(bracketed.port == 2222)
    }

    /// The one that matters. `-oProxyCommand=...` in the host field is a local command execution
    /// and is spelled exactly like a host name.
    @Test("a destination that looks like an option is refused", .tags(.security))
    func optionInjection() {
        #expect(throws: SSHDestinationProblem.looksLikeAnOption) {
            try SSHDestination.parse("-oProxyCommand=/bin/sh -c id")
        }
        #expect(throws: SSHDestinationProblem.looksLikeAnOption) {
            try SSHDestination.parse("root@-oProxyCommand=x")
        }
    }

    @Test("whitespace, empty halves and bad ports are refused")
    func refusals() {
        #expect(throws: SSHDestinationProblem.empty) { try SSHDestination.parse("   ") }
        #expect(throws: SSHDestinationProblem.containsWhitespace) {
            try SSHDestination.parse("deploy@vps example.com")
        }
        #expect(throws: SSHDestinationProblem.missingUser) { try SSHDestination.parse("@vps") }
        #expect(throws: SSHDestinationProblem.missingHost) { try SSHDestination.parse("deploy@") }
        #expect(throws: SSHDestinationProblem.badPort("0")) {
            try SSHDestination.parse("vps:0")
        }
        #expect(throws: SSHDestinationProblem.badPort("nope")) {
            try SSHDestination.parse("vps:nope")
        }
    }

    @Test("surrounding whitespace is trimmed rather than refused")
    func trimmed() throws {
        #expect(try SSHDestination.parse("  root@vps  ").host == "vps")
    }

    @Test("the suggested label is the host without its domain")
    func label() throws {
        #expect(try SSHDestination.parse("deploy@vps.example.com").suggestedLabel == "vps")
        #expect(try SSHDestination.parse("vps").suggestedLabel == "vps")
        // An address has dots in it and none of them separate a name from a domain. Measured
        // against the throwaway VPS this was built on, where the first-component rule named the
        // server "94".
        #expect(try SSHDestination.parse("root@94.237.125.23").suggestedLabel == "94.237.125.23")
        #expect(try SSHDestination.parse("root@2001:db8::1").suggestedLabel == "2001:db8::1")
    }
}
