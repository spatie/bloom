import AppKit
import ServiceManagement
import BloomCore

/// Bloom's half of the conversation with `bloom-sleep-helper`: the privileged daemon that turns the
/// system's sleep switch off while a Keep Awake session runs, which is the only thing that holds a
/// Mac open with the lid shut.
///
/// See the helper's own file for why this is a daemon rather than an assertion. Everything here is
/// best effort and says so: a build that is not signed with Bloom's certificate cannot register a
/// daemon at all, and an approval nobody has granted yet leaves the switch alone. Keep Awake keeps
/// working in both cases; it just cannot cover the lid.
@MainActor
@Observable
final class SleepSwitch {
    static let shared = SleepSwitch()

    enum Standing: Equatable {
        /// Approved, and the switch can be flipped.
        case ready
        /// Registered, and waiting for somebody to allow it in System Settings.
        case needsApproval
        /// This build cannot register a daemon, which is every ad hoc signed build.
        case unavailable(String)
    }

    private(set) var standing: Standing = .needsApproval

    @ObservationIgnored private let service = SMAppService.daemon(plistName: "be.spatie.bloom.sleep.plist")
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var connectionID: UUID?

    private init() {
        refreshStanding()
        // Approving happens in System Settings, so the answer changes while Bloom is in the
        // background and nothing here would ever hear about it. Without this the pane goes on
        // saying "Allow Bloom's helper" after somebody already has.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SleepSwitch.shared.refresh() }
        }
    }

    /// Reads the daemon's standing again. Cheap, and the only way to notice an approval.
    func refresh() {
        refreshStanding()
    }

    /// Registers the daemon if it is not registered, and reports where that got to. Called when
    /// somebody switches the lid option on, which is the only moment it is worth asking for.
    @discardableResult
    func enable() -> Standing {
        switch service.status {
        case .enabled:
            standing = .ready
        case .requiresApproval:
            standing = .needsApproval
        case .notRegistered, .notFound:
            do {
                try service.register()
                refreshStanding()
            } catch {
                // A helper cannot be registered from a build signed ad hoc, which is what
                // `Tools/dev-build.sh` produces unless it is handed a real identity.
                standing = .unavailable(TranscriptStanding.complaint(about: error))
            }
        @unknown default:
            standing = .needsApproval
        }
        return standing
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Asks the daemon to hold the lid, or to let go of it. Nothing happens, loudly or quietly,
    /// when there is no approved daemon to ask.
    func setHoldingLidClosed(_ held: Bool) {
        refreshStanding()
        guard standing == .ready else { return }
        proxy()?.setSleepDisabled(held, clientPID: ProcessInfo.processInfo.processIdentifier, withReply: Self.ignoreReply)
    }

    /// Puts the switch back, whatever a session thought. Called on the way out, so quitting Bloom
    /// never leaves a Mac that will not sleep.
    func releaseOnQuit() {
        guard case .ready = standing else { return }
        proxy()?.setSleepDisabled(false, clientPID: ProcessInfo.processInfo.processIdentifier, withReply: Self.ignoreReply)
    }

    private func refreshStanding() {
        switch service.status {
        case .enabled: standing = .ready
        case .requiresApproval: standing = .needsApproval
        case .notRegistered, .notFound: if case .unavailable = standing {} else { standing = .needsApproval }
        @unknown default: standing = .needsApproval
        }
    }

    private func proxy() -> SleepControl? {
        if connection == nil {
            let identifier = UUID()
            let created = NSXPCConnection(machServiceName: "be.spatie.bloom.sleep", options: .privileged)
            created.remoteObjectInterface = NSXPCInterface(with: SleepControl.self)
            let invalidated = Self.invalidationHandler(owner: self, identifier: identifier)
            created.invalidationHandler = invalidated
            created.interruptionHandler = invalidated
            connection = created
            connectionID = identifier
            created.resume()
        }
        guard let connectionID else { return nil }
        let invalidated = Self.invalidationHandler(owner: self, identifier: connectionID)
        return connection?.remoteObjectProxyWithErrorHandler(Self.errorHandler(invalidated)) as? SleepControl
    }

    private func invalidateConnection(_ identifier: UUID) {
        guard connectionID == identifier else { return }
        let previous = connection
        connection = nil
        connectionID = nil
        previous?.invalidate()
    }

    // XPC invokes these blocks on its own queue. Build them outside MainActor isolation;
    // even an empty closure created in proxy() otherwise inherits a runtime actor assertion.
    private nonisolated static func invalidationHandler(owner: SleepSwitch, identifier: UUID) -> @Sendable () -> Void {
        { [weak owner] in
            Task { @MainActor in owner?.invalidateConnection(identifier) }
        }
    }

    private nonisolated static func errorHandler(_ invalidated: @escaping @Sendable () -> Void) -> @Sendable (any Error) -> Void {
        { _ in invalidated() }
    }

    private nonisolated static func ignoreReply(_ result: Bool) {}

}

/// The daemon's side of the wire, declared again here rather than shared through a module: the
/// helper is a hundred lines with no dependencies, and linking the whole of `BloomCore` into a
/// root daemon to share two method signatures would be the wrong trade.
@objc protocol SleepControl {
    func setSleepDisabled(_ disabled: Bool, clientPID: Int32, withReply reply: @escaping (Bool) -> Void)
    func readSleepDisabled(withReply reply: @escaping (Bool) -> Void)
}
