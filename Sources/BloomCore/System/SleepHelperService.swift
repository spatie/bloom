import Foundation

/// ServiceManagement's status read is synchronous IPC, measured at about 300 ms on activation.
/// Keep it and registration on this actor, including the read after registering. The injected
/// operations keep ServiceManagement in the app target and let the core exercise approval changes.
public actor SleepHelperService {
    public enum Status: Sendable {
        case enabled, requiresApproval, notRegistered, notFound
    }

    public enum Standing: Equatable, Sendable {
        case ready
        case needsApproval
        case unavailable(String)
    }

    private let readStatus: @Sendable () -> Status
    private let register: @Sendable () throws -> Void
    private var standing: Standing = .needsApproval

    public init(
        readStatus: @escaping @Sendable () -> Status,
        register: @escaping @Sendable () throws -> Void
    ) {
        self.readStatus = readStatus
        self.register = register
    }

    @discardableResult
    public func refresh() -> Standing {
        switch readStatus() {
        case .enabled: standing = .ready
        case .requiresApproval: standing = .needsApproval
        case .notRegistered, .notFound:
            if case .unavailable = standing {} else { standing = .needsApproval }
        }
        return standing
    }

    public func enable() -> Standing {
        switch readStatus() {
        case .enabled:
            standing = .ready
        case .requiresApproval:
            standing = .needsApproval
        case .notRegistered, .notFound:
            do {
                try register()
                refresh()
            } catch {
                standing = .unavailable(TranscriptStanding.complaint(about: error))
            }
        }
        return standing
    }
}
