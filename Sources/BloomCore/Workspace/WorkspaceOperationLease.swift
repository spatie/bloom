import Foundation
import Synchronization

/// Two setup runs must not write the same worktree at once. The reservation is synchronous:
/// checking another actor and launching later leaves a window for the other run to start.
public final class WorkspaceOperationLease: Sendable {
    private static let claims = Mutex<[String: UUID]>([:])
    private let path: String
    private let token: UUID

    private init(path: String, token: UUID) {
        self.path = path
        self.token = token
    }

    public static func acquire(in worktree: String) -> WorkspaceOperationLease? {
        let path = canonical(worktree)
        let token = UUID()
        let claimed = claims.withLock { claims in
            guard claims[path] == nil else { return false }
            claims[path] = token
            return true
        }
        return claimed ? WorkspaceOperationLease(path: path, token: token) : nil
    }

    public func isValid(in worktree: String) -> Bool {
        guard path == Self.canonical(worktree) else { return false }
        return Self.claims.withLock { $0[path] == token }
    }

    public func release() {
        Self.claims.withLock { claims in
            if claims[path] == token { claims[path] = nil }
        }
    }

    deinit { release() }

    private static func canonical(_ worktree: String) -> String {
        URL(fileURLWithPath: worktree).resolvingSymlinksInPath().standardized.path
    }
}
