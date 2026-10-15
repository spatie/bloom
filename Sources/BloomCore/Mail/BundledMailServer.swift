import Darwin
import Foundation

/// Owns Bloom's SMTP server. The small supervisor keeps the server tied to this app process even
/// if Bloom crashes: closing the pipe on exit is its signal to stop Mailpit.
@MainActor
public final class BundledMailServer {
    public enum Failure: LocalizedError, Equatable {
        case missing
        case invalidSMTPPort(Int)
        case smtpPortInUse(Int)
        case apiPortInUse(Int)
        case restarting

        public var errorDescription: String? {
            switch self {
            case .missing: "The built-in inbox is missing from this Bloom installation."
            case .invalidSMTPPort(let port): "SMTP port \(port) cannot be used. Choose a port from 1024 to 65535 that differs from Bloom's inbox port."
            case .smtpPortInUse(let port): "SMTP port \(port) is already in use. Choose another port in Settings or stop the app using it."
            case .apiPortInUse(let port): "Bloom's inbox port \(port) is already in use. Stop the app using it and try again."
            case .restarting: "Restarting the inbox."
            }
        }
    }

    private var supervisor: Process?
    private var input: Pipe?
    private var activePorts: MailpitSettings.Ports?
    private var stopping: Process?
    private let executableDirectory: URL?
    private let dataDirectory: URL?

    public init(executableDirectory: URL? = nil, dataDirectory: URL? = nil) {
        self.executableDirectory = executableDirectory
        self.dataDirectory = dataDirectory
    }

    public var isRunning: Bool { supervisor?.isRunning == true }
    var processIdentifier: Int32? { isRunning ? supervisor?.processIdentifier : nil }

    public func start(ports: MailpitSettings.Ports) throws {
        guard MailpitSettings.isValidSMTPPort(ports.smtp, forAPIport: ports.api) else {
            throw Failure.invalidSMTPPort(ports.smtp)
        }
        if supervisor != nil && !isRunning { stop() }
        if isRunning && activePorts == ports { return }
        if isRunning { stop() }
        if stopping?.isRunning == true { throw Failure.restarting }
        stopping = nil

        guard let executables = executableDirectory ?? Bundle.main.executableURL?.deletingLastPathComponent() else {
            throw Failure.missing
        }
        let mailpit = executables.appendingPathComponent("mailpit")
        let helper = executables.appendingPathComponent("bloom-mail-server")
        guard FileManager.default.isExecutableFile(atPath: mailpit.path),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw Failure.missing
        }
        if let conflict = Self.portConflict(for: ports) { throw conflict }

        let directory: URL
        if let dataDirectory {
            directory = dataDirectory
        } else {
            directory = URL(fileURLWithPath: try Store.defaultPath()).deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = [
            mailpit.path,
            directory.appendingPathComponent("incoming-mails.sqlite").path,
            String(ports.smtp),
            String(ports.api),
            directory.appendingPathComponent("incoming-mails.log").path,
        ]
        // Mailpit reads MP_* environment variables, including forwarding and relay settings.
        // Inheriting Bloom's environment could turn a local test inbox into a mail sender.
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        supervisor = process
        input = pipe
        activePorts = ports
    }

    public func stop() {
        // The helper reads until EOF, then terminates and reaps its Mailpit child. Terminating the
        // helper here instead would strand that child on the SMTP port.
        if supervisor?.isRunning == true { stopping = supervisor }
        input?.fileHandleForWriting.closeFile()
        input = nil
        supervisor = nil
        activePorts = nil
    }

    /// Check again after an unexpected early exit, since another process can take a port between
    /// the preflight check and Mailpit binding its listeners.
    public static func portConflict(for ports: MailpitSettings.Ports) -> Failure? {
        if !isAvailable(ports.smtp) { return .smtpPortInUse(ports.smtp) }
        if !isAvailable(ports.api) { return .apiPortInUse(ports.api) }
        return nil
    }

    private static func isAvailable(_ port: Int) -> Bool {
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
}
