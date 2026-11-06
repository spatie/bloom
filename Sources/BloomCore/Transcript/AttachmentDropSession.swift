import Foundation

/// Owns provider loads and delayed file-promise delivery for one attachment destination.
/// A cancelled destination stays cancelled, including when an AppKit promise cannot be stopped.
@MainActor
public final class AttachmentDropSession {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public private(set) var isActive = true

    public init() {}

    @discardableResult
    public func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    /// File promises can call back after their sheet closed. The callback and cancellation both
    /// run on the main actor, so a delivery cannot slip between the lifetime check and its write.
    public func deliver(_ operation: @MainActor () -> Void) {
        guard isActive else { return }
        operation()
    }

    public func cancelAll() {
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
