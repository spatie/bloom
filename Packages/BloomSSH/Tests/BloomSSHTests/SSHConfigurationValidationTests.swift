import Foundation
import Testing
import BloomClient
@testable import BloomSSH

struct SSHConfigurationValidationTests {
    @Test(arguments: ["", "not a server", "https://example.com", "host\0name", "host\nname", "host\rname"])
    func invalidAddressNamesOnlyTheAddress(_ host: String) {
        let error = #expect(throws: ConnectionFailure.self) { try SSHConfiguration(host: host, username: "bloom") }
        #expect(error?.localizedDescription == "Enter a server IP address or hostname without spaces or a URL path.")
    }

    @Test(arguments: [-1, 0, 65_536])
    func invalidPortShowsItsRange(_ port: Int) {
        let error = #expect(throws: ConnectionFailure.self) { try SSHConfiguration(host: "example.com", port: port, username: "bloom") }
        #expect(error?.localizedDescription == "Enter an SSH port from 1 to 65535.")
    }

    @Test(arguments: ["", "two names", "bloom@host", "user\0name", "user\nname", "user\rname"])
    func invalidUsernameNamesOnlyTheAccount(_ username: String) {
        let error = #expect(throws: ConnectionFailure.self) { try SSHConfiguration(host: "example.com", username: username) }
        #expect(error?.localizedDescription == "Enter an SSH username without spaces or @, usually bloom.")
    }

    @Test(arguments: ["", "bad\ncommand", "bad\rcommand", "bad\0command"])
    func invalidExecutableNamesItsField(_ executable: String) {
        let error = #expect(throws: ConnectionFailure.self) {
            try SSHConfiguration(host: "example.com", username: "bloom", executable: executable)
        }
        #expect(error?.localizedDescription == "Enter the Bloom Server executable path on one line.")
    }

    @Test(arguments: ["", "relative/data", "/data\ncommand", "/data\rcommand", "/data\0command"])
    func invalidDataDirectoryExplainsAbsolutePaths(_ path: String) {
        let error = #expect(throws: ConnectionFailure.self) {
            try SSHConfiguration(host: "example.com", username: "bloom", dataDirectory: path)
        }
        #expect(error?.localizedDescription == "Enter an absolute server data directory beginning with /, such as /home/bloom/bloom/data.")
    }

    @Test func preservesNormalisationAndCustomCommandQuoting() throws {
        let configuration = try SSHConfiguration(host: " EXAMPLE.COM\n", port: 65_535, username: "bloom",
            executable: "server's binary", dataDirectory: "/data with spaces")
        #expect(configuration.host == "example.com")
        #expect(configuration.port == 65_535)
        #expect(configuration.command == "'server'\\''s binary' connect --data-dir '/data with spaces'")
    }
}
