/// Coalesces repeated requests for a refresh without losing freshness.
///
/// The first request starts work. Requests made while that work is running do not start parallel
/// copies, but they remember that the caller wanted an answer newer than the run already under
/// way. `complete()` then asks the owner for exactly one final run after that burst.
public struct RefreshDemand: Sendable {
    public private(set) var isRunning = false
    private var isPending = false

    public init() {}

    /// True when the caller should start the first run of a refresh cycle.
    public mutating func request() -> Bool {
        guard !isRunning else {
            isPending = true
            return false
        }
        isRunning = true
        return true
    }

    /// True when another run was requested while the last one was under way.
    public mutating func complete() -> Bool {
        guard isPending else {
            isRunning = false
            return false
        }
        isPending = false
        return true
    }
}
