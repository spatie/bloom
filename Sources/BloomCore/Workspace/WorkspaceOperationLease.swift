import Foundation
import Synchronization

/// Setup and history restoration both write the same worktree. Their reservation must be
/// synchronous: checking another actor and launching later leaves a window for the other writer.
public final class WorkspaceOperationLease: Sendable {
    public enum Operation: Sendable, Equatable { case setup, rewind }

    private struct Claim: Sendable {
        let token: UUID
        let operation: Operation
    }
    private static let claims = Mutex<[String: Claim]>([:])
    private let path: String
    private let token: UUID
    private let operation: Operation

    private init(path: String, token: UUID, operation: Operation) {
        self.path = path
        self.token = token
        self.operation = operation
    }

    public static func acquire(in worktree: String, operation: Operation) -> WorkspaceOperationLease? {
        let path = canonical(worktree)
        let token = UUID()
        let claimed = claims.withLock { claims in
            guard claims[path] == nil else { return false }
            claims[path] = Claim(token: token, operation: operation)
            return true
        }
        return claimed ? WorkspaceOperationLease(path: path, token: token, operation: operation) : nil
    }

    public func isValid(in worktree: String, operation: Operation) -> Bool {
        guard path == Self.canonical(worktree), self.operation == operation else { return false }
        return Self.claims.withLock { $0[path]?.token == token }
    }

    public static func isHeld(in worktree: String, operation: Operation) -> Bool {
        let path = canonical(worktree)
        return claims.withLock { $0[path]?.operation == operation }
    }

    public func release() {
        Self.claims.withLock { claims in
            if claims[path]?.token == token { claims[path] = nil }
        }
    }

    deinit { release() }

    private static func canonical(_ worktree: String) -> String {
        URL(fileURLWithPath: worktree).resolvingSymlinksInPath().standardized.path
    }
}
