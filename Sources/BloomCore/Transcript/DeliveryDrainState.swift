/// Coalesces requests made while a delivery awaits its runner, without allowing two senders.
public enum DeliveryDrainState: Sendable {
    case idle
    case active
    case requested

    public mutating func begin() -> Bool {
        guard case .idle = self else {
            self = .requested
            return false
        }
        self = .active
        return true
    }

    public mutating func finish(allowRepeat: Bool = true) -> Bool {
        let again = self == .requested && allowRepeat
        self = .idle
        return again
    }
}
