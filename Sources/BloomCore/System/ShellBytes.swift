import Foundation

/// Structured command output stays as bytes until its caller chooses an encoding. In particular,
/// Git's NUL-delimited filenames must never make a lossy trip through a String.
public struct ShellBytes: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum ShellFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case timedOut(command: String)
    case outputLimit(command: String, stream: String, limit: Int)
    case incompleteOutput(command: String)
    case pipe(command: String, operation: String, code: Int32)

    public var description: String {
        switch self {
        case .timedOut(let command): "\(command) timed out."
        case .outputLimit(let command, let stream, let limit):
            "\(command) produced more than \(limit) bytes on \(stream)."
        case .incompleteOutput(let command):
            "\(command) exited, but a child process kept its output open."
        case .pipe(let command, let operation, let code):
            "Could not \(operation) for \(command): \(String(cString: strerror(code)))."
        }
    }
}
