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

    private init() {
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
        let proxy = proxy { [weak self] in
            MainActor.assumeIsolated { self?.connection = nil }
        }
        proxy?.setSleepDisabled(held, clientPID: ProcessInfo.processInfo.processIdentifier) { _ in }
    }

    /// Puts the switch back, whatever a session thought. Called on the way out, so quitting Bloom
    /// never leaves a Mac that will not sleep.
    func releaseOnQuit() {
        guard case .ready = standing else { return }
        proxy(onInvalidation: {})?.setSleepDisabled(false, clientPID: ProcessInfo.processInfo.processIdentifier) { _ in }
    }

    private func refreshStanding() {
        switch service.status {
        case .enabled: standing = .ready
        case .requiresApproval: standing = .needsApproval
        case .notRegistered, .notFound: if case .unavailable = standing {} else { standing = .needsApproval }
        @unknown default: standing = .needsApproval
        }
    }

    private func proxy(onInvalidation: @escaping @Sendable () -> Void) -> SleepControl? {
        if connection == nil {
            let created = NSXPCConnection(machServiceName: "be.spatie.bloom.sleep", options: .privileged)
            created.remoteObjectInterface = NSXPCInterface(with: SleepControl.self)
            created.invalidationHandler = onInvalidation
            created.resume()
            connection = created
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in } as? SleepControl
    }
}

/// The daemon's side of the wire, declared again here rather than shared through a module: the
/// helper is a hundred lines with no dependencies, and linking the whole of `BloomCore` into a
/// root daemon to share two method signatures would be the wrong trade.
@objc protocol SleepControl {
    func setSleepDisabled(_ disabled: Bool, clientPID: Int32, withReply reply: @escaping (Bool) -> Void)
    func readSleepDisabled(withReply reply: @escaping (Bool) -> Void)
}
