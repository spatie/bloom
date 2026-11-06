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

    typealias Standing = SleepHelperService.Standing

    private(set) var standing: Standing = .needsApproval

    @ObservationIgnored private let service = SleepHelperService(
        readStatus: {
            switch SMAppService.daemon(plistName: "be.spatie.bloom.sleep.plist").status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notRegistered: .notRegistered
            case .notFound: .notFound
            @unknown default: .requiresApproval
            }
        },
        register: { try SMAppService.daemon(plistName: "be.spatie.bloom.sleep.plist").register() }
    )
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var updates: Task<Standing, Never>?
    @ObservationIgnored private var refreshTask: Task<Standing, Never>?
    @ObservationIgnored private var enableTask: Task<Standing, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var requestedHold: Bool?

    private init() {
        // ServiceManagement performs synchronous IPC. Never read its status in an activation
        // observer, even through a main-actor Task. Approval is noticed by this slow background
        // refresh and by the shorter watch while a helper settings pane is visible.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @discardableResult
    func refresh() async -> Standing {
        if let refreshTask { return await refreshTask.value }
        let task = updateStanding(register: false)
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Owned by the settings view's task, so the shorter approval watch ends with the pane.
    func watchStanding() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: .seconds(standing == .needsApproval ? 3 : 30))
            } catch { return }
        }
    }

    @discardableResult
    func enable() async -> Standing {
        if let enableTask { return await enableTask.value }
        let task = updateStanding(register: true)
        enableTask = task
        let result = await task.value
        enableTask = nil
        return result
    }

    /// Publish in request order as well as performing the IPC in order. Otherwise a refresh
    /// suspended before registration could overwrite its newer result on the main actor.
    private func updateStanding(register: Bool) -> Task<Standing, Never> {
        let previous = updates
        let task = Task {
            _ = await previous?.value
            let result = register ? await service.enable() : await service.refresh()
            if standing != result {
                standing = result
                applyRequestedHold()
            }
            return result
        }
        updates = task
        return task
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Asks the daemon to hold the lid, or to let go of it. Nothing happens, loudly or quietly,
    /// when there is no approved daemon to ask.
    func setHoldingLidClosed(_ held: Bool) {
        requestedHold = held
        applyRequestedHold()
    }

    private func applyRequestedHold() {
        guard let held = requestedHold, standing == .ready else { return }
        // Hopped rather than assumed: NSXPCConnection calls its invalidation handler on its own
        // queue, and `assumeIsolated` there is a trap rather than a check.
        let proxy = proxy { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        proxy?.setSleepDisabled(held, clientPID: ProcessInfo.processInfo.processIdentifier, withReply: Self.ignoreReply)
    }

    /// Puts the switch back, whatever a session thought. Called on the way out, so quitting Bloom
    /// never leaves a Mac that will not sleep.
    func releaseOnQuit() {
        guard case .ready = standing else { return }
        proxy(onInvalidation: {})?.setSleepDisabled(
            false, clientPID: ProcessInfo.processInfo.processIdentifier, withReply: Self.ignoreReply
        )
    }

    private func proxy(onInvalidation: @escaping @Sendable () -> Void) -> SleepControl? {
        if connection == nil {
            let created = NSXPCConnection(machServiceName: "be.spatie.bloom.sleep", options: .privileged)
            created.remoteObjectInterface = NSXPCInterface(with: SleepControl.self)
            created.invalidationHandler = onInvalidation
            created.resume()
            connection = created
        }
        return connection?.remoteObjectProxyWithErrorHandler(Self.ignoreError) as? SleepControl
    }

    /// The reply and the error handler XPC calls back on its own queue, declared outside the
    /// class's main actor. Written inline as `{ _ in }` inside a method of this class, each closure
    /// inherited main actor isolation, and Swift checks that on entry: the first time the daemon
    /// was unreachable, the error handler ran on XPC's queue and Bloom stopped at launch in
    /// `dispatch_assert_queue`.
    private nonisolated static let ignoreReply: @Sendable (Bool) -> Void = { _ in }
    private nonisolated static let ignoreError: @Sendable (any Error) -> Void = { _ in }
}

/// The daemon's side of the wire, declared again here rather than shared through a module: the
/// helper is a hundred lines with no dependencies, and linking the whole of `BloomCore` into a
/// root daemon to share two method signatures would be the wrong trade.
@objc protocol SleepControl {
    func setSleepDisabled(_ disabled: Bool, clientPID: Int32, withReply reply: @escaping (Bool) -> Void)
    func readSleepDisabled(withReply reply: @escaping (Bool) -> Void)
}
