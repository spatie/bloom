import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace preview")
struct WorkspacePreviewTests {
    @Test("Browser-first setup waits, then opens the allocated workspace port")
    func waitsForSetup() {
        for state in [SetupState.pending, .running] {
            #expect(opening(setup: state) == .wait)
        }
        for state in [SetupState.succeeded, .skipped] {
            #expect(opening(setup: state) == .open("http://localhost:3190"))
        }
    }

    @Test("A failed setup waits for a successful retry without losing the untouched preview")
    func failureAndRetry() {
        #expect(opening(setup: .failed) == .wait)
        #expect(opening(setup: .running) == .wait)
        #expect(opening(setup: .succeeded) == .open("http://localhost:3190"))
        #expect(opening(setup: .failed, address: "example.com") == .discard)
        #expect(opening(setup: .failed, hasNavigated: true) == .discard)
        #expect(opening(pending: false, setup: .succeeded) == .discard)
    }

    @Test("Typing, saved navigation and an in-flight navigation each prevent a takeover")
    func doesNotHijack() {
        #expect(opening(address: "example") == .discard)
        #expect(opening(storedAddress: "https://example.com") == .discard)
        #expect(opening(hasNavigated: true) == .discard)
    }

    @Test("Unallocated or invalid ports cannot open a preview")
    func validatesPort() {
        for port in [0, -1, 65_536] {
            #expect(WorkspacePreview.address(port: port) == nil)
            #expect(opening(port: port) == .wait)
        }
    }

    @Test("Forwarded previews retain the workspace origin during page navigation")
    func preservesWorkspaceAddress() throws {
        for destination in ["http://127.0.0.1:51234", "https://preview.example.com"] {
            let mapping = try #require(BrowserPreviewAddress(original: "http://localhost:3190", resolved: destination))
            #expect(mapping.display(destination + "/tickets?filter=open#latest") == "http://localhost:3190/tickets?filter=open#latest")
            #expect(mapping.display("https://other.example.com/login") == nil)
            #expect(mapping.display("http://127.0.0.1:51235/tickets") == nil)
        }
    }

    @Test("Canonical HTTPS redirects retain the same preview mapping")
    func canonicalOrigin() throws {
        let mapping = try #require(BrowserPreviewAddress(original: "http://localhost:3190", resolved: "https://PREVIEW.example.com:443"))
        #expect(mapping.display("https://preview.example.com/login") == "http://localhost:3190/login")
        #expect(mapping.display("http://preview.example.com/login") == nil)
        #expect(mapping.display("https://user@preview.example.com/login") == nil)
    }

    @Test("External redirects and path-based proxies are not disguised as workspace URLs")
    func rejectsUnrelatedMapping() {
        #expect(BrowserPreviewAddress(original: "https://example.com", resolved: "http://127.0.0.1:1234") == nil)
        #expect(BrowserPreviewAddress(original: "http://localhost:3190", resolved: "https://preview.example.com/prefix") == nil)
        #expect(BrowserPreviewAddress(original: "http://localhost:3190", resolved: "https://user@preview.example.com") == nil)
    }

    @Test("Loopback preview labels name the remote server without changing the address")
    func remoteLocality() {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let address = "http://\(host):3190/tickets"
            let display = BrowserAddressDisplay.of(address, remoteServer: "Development")
            #expect(display.security == .remote(server: "Development"))
            #expect(display.security.help == "A preview on Development")
            #expect(display.leading + display.host + display.trailing == address)
        }
        #expect(BrowserAddressDisplay.of("http://localhost:3190").security == .local)
        #expect(BrowserAddressDisplay.of("https://example.com", remoteServer: "Development").security == .secure)
        #expect(BrowserAddressDisplay.of("http://example.com", remoteServer: "Development").security == .insecure)
        #expect(BrowserAddressDisplay.of("http://localhost.evil.com", remoteServer: "Development").security != .remote(server: "Development"))
    }

    private func opening(
        pending: Bool = true, setup: SetupState = .succeeded, port: Int = 3190,
        address: String = "", storedAddress: String = "", hasNavigated: Bool = false
    ) -> WorkspacePreview.Opening {
        WorkspacePreview.opening(pending: pending, setup: setup, port: port, address: address,
            storedAddress: storedAddress, hasNavigated: hasNavigated)
    }
}
