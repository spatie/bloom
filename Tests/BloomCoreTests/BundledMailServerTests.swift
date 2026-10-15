import Darwin
import Foundation
import Testing
@testable import BloomCore

@Suite("Bundled mail server")
@MainActor
struct BundledMailServerTests {
    @Test("SMTP cannot share the inbox port")
    func samePort() throws {
        let server = BundledMailServer()
        do {
            try server.start(ports: .init(smtp: 8026, api: 8026))
            Issue.record("The inbox port was accepted for SMTP")
        } catch let failure as BundledMailServer.Failure {
            #expect(failure == .invalidSMTPPort(8026))
            #expect(failure.localizedDescription.contains("differs from Bloom's inbox port"))
        }
    }

    @Test("an occupied SMTP port names the port and tells the user what to do")
    func occupiedSMTPPort() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let smtp = try reservePort()
        defer { Darwin.close(smtp.descriptor) }
        let api = try reservePort()
        defer { Darwin.close(api.descriptor) }
        let server = fixture.server

        do {
            try server.start(ports: .init(smtp: smtp.port, api: api.port))
            Issue.record("The occupied SMTP port was accepted")
        } catch let failure as BundledMailServer.Failure {
            #expect(failure == .smtpPortInUse(smtp.port))
            #expect(failure.localizedDescription.contains("Choose another port in Settings"))
        }
        #expect(!server.isRunning)
    }

    @Test("an occupied internal port has a different, actionable error")
    func occupiedAPIPort() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let smtp = try reservePort()
        let api = try reservePort()
        Darwin.close(smtp.descriptor)
        defer { Darwin.close(api.descriptor) }
        let server = fixture.server

        do {
            try server.start(ports: .init(smtp: smtp.port, api: api.port))
            Issue.record("The occupied inbox port was accepted")
        } catch let failure as BundledMailServer.Failure {
            #expect(failure == .apiPortInUse(api.port))
            #expect(failure.localizedDescription.contains("Stop the app using it"))
        }
        #expect(!server.isRunning)
    }

    @Test("changing the SMTP port replaces the process and releases its old listener")
    func changingPortRestarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSMTP = try reservePort()
        let api = try reservePort()
        let secondSMTP = try reservePort()
        Darwin.close(firstSMTP.descriptor)
        Darwin.close(api.descriptor)
        Darwin.close(secondSMTP.descriptor)
        let server = fixture.server
        defer { server.stop() }

        try server.start(ports: .init(smtp: firstSMTP.port, api: api.port))
        let firstPID = try #require(server.processIdentifier)
        let firstReady = await eventually { !isPortFree(firstSMTP.port) && !isPortFree(api.port) }
        #expect(firstReady)

        // The old helper exits after EOF. A restart can briefly report `.restarting`; the
        // thirty-second ceiling catches a helper that never releases its listener.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var secondPID: Int32?
        while ContinuousClock.now < deadline {
            do {
                try server.start(ports: .init(smtp: secondSMTP.port, api: api.port))
                secondPID = server.processIdentifier
                break
            } catch BundledMailServer.Failure.restarting {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let replacement = try #require(secondPID)
        #expect(replacement != firstPID)
        let secondReady = await eventually {
            isPortFree(firstSMTP.port) && !isPortFree(secondSMTP.port) && !isPortFree(api.port)
        }
        #expect(secondReady)
    }

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-mail-test-\(UUID())")

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let helper = directory.appendingPathComponent("bloom-mail-server")
            let script = """
            #!/usr/bin/python3
            import socket, sys
            listeners = []
            for port in (int(sys.argv[3]), int(sys.argv[4])):
                listener = socket.socket()
                listener.bind(("127.0.0.1", port))
                listener.listen()
                listeners.append(listener)
            sys.stdin.buffer.read()
            """
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let binary = directory.appendingPathComponent("mailpit")
            try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }

        var server: BundledMailServer {
            BundledMailServer(executableDirectory: directory, dataDirectory: directory)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Reservation {
        let descriptor: Int32
        let port: Int
    }

    private func reservePort() throws -> Reservation {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        return Reservation(descriptor: descriptor, port: Int(UInt16(bigEndian: address.sin_port)))
    }

    private func isPortFree(_ port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
