/// A pane acknowledges an explicit scroll only after its conversation has arrived. Requests
/// sent while the pane is absent must survive rebuilding it and restoring its saved position.
public struct TranscriptLiveEndRequest: Equatable, Sendable {
    public private(set) var handled: Int

    public init(handled: Int = 0) {
        self.handled = handled
    }

    public mutating func consume(_ requested: Int, isReady: Bool) -> Bool {
        guard isReady, requested > handled else { return false }
        handled = requested
        return true
    }
}
