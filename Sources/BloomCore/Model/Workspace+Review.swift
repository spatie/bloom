import Foundation

public extension Workspace {
    /// The project's checkout can switch branches or detach before its stored branch catches up.
    /// Its review and Discard must only ever measure uncommitted work against the actual HEAD.
    var reviewBase: String { kind == .projectCheckout ? "HEAD" : baseBranch }
}
