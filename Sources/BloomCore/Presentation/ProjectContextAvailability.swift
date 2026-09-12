/// A missing context is only loading while an actual request is running.
public enum ProjectContextAvailability: Equatable, Sendable {
    case waiting, loading, ready, disconnected, connecting, failed(String)

    public static func resolve(isRemote: Bool, isConnected: Bool, isConnecting: Bool,
                               hasLoaded: Bool, isLoading: Bool, error: String?) -> Self {
        if isRemote {
            if isConnecting { return .connecting }
            if !isConnected { return .disconnected }
        }
        if isLoading { return .loading }
        if let error { return .failed(error) }
        return hasLoaded ? .ready : .waiting
    }

    public var allowsActions: Bool { self == .ready }
}
