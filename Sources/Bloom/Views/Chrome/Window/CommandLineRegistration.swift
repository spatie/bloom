import BloomCore
import Foundation
import Observation

/// The welcome window's model for its optional last step: what the command is, and whether it is
/// worth offering at all.
///
/// Not a view, for the reason `SetupInspection` is not one. Both answers here come off the disk,
/// one of them out of a file that belongs to another program and can be very large, and a `body`
/// that read them would read them again on every redraw.
///
/// **Two things have to be true before the step exists.** This copy of Bloom has to have a bridge
/// to point at, which a build assembled without the shim beside it does not, and the owner's own
/// user scope must not already be pointing at it. The second is what stops the window holding out
/// a command somebody ran last week; the rule itself is `BridgeUserRegistration` in the core, with
/// tests, and nothing here decides anything it could get wrong on its own.
@MainActor
@Observable
final class CommandLineRegistration {
    /// The line to run, or nil when there is nothing to offer.
    private(set) var command: String?
    /// Whether the window should carry the step at all. False until the answer is in, so a window
    /// somebody walks through in the first half second ends where it always did rather than
    /// growing a screen under them.
    private(set) var isOffered = false

    /// Where the attachment comes from, asked each time rather than held, because the bridge is
    /// bound during `AppModel.bootstrap` and this window can be on screen before that has
    /// happened. See `wait`.
    private let source: @MainActor () -> BridgeAttachment?
    private var run: Task<Void, Never>?

    init(source: @escaping @MainActor () -> BridgeAttachment?) {
        self.source = source
    }

    /// Asks again, from the top. Called when the window opens and on every later visit, because
    /// somebody who comes back may have run the command in between.
    func resolve() {
        run?.cancel()
        run = Task { [weak self] in
            guard let self else { return }
            guard let attachment = await self.wait() else {
                self.settle(command: nil, isOffered: false)
                return
            }
            let config = await Self.readUserConfig()
            let state = BridgeUserRegistration.state(
                userConfig: config,
                serverNamed: BridgeRegistration.ownerServerName,
                matching: attachment
            )
            guard !Task.isCancelled else { return }
            // Anything but a match is offered. `unknown` is a file that could not be read, which
            // is a machine to offer the command to rather than one to assume about, and the cost
            // of offering it twice is a screen somebody presses past.
            self.settle(
                command: BridgeRegistration.ownerAddCommand(attachment),
                isOffered: state != .registered
            )
        }
    }

    func cancel() {
        run?.cancel()
        run = nil
    }

    private func settle(command: String?, isOffered: Bool) {
        self.command = command
        self.isOffered = isOffered
        run = nil
    }

    /// The attachment, waiting a little for it if the app is still starting.
    ///
    /// A first launch opens this window from `applicationDidFinishLaunching`, and the socket is
    /// bound in `AppModel.bootstrap`, which is the scene's own `.task`. Asking once would
    /// therefore decide there was nothing to offer on the one launch this step exists for. The
    /// shape is `RunningApp.waitUntilReady`'s and the deadline is short: nobody is waiting on
    /// this, and a bridge that has not appeared in three seconds is one that failed to bind.
    private func wait(timeout: Duration = .seconds(3)) async -> BridgeAttachment? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let attachment = source() { return attachment }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return nil }
        }
        return source()
    }

    /// `~/.claude.json`, off the main actor.
    ///
    /// It is Claude Code's own file and it carries every project that CLI has ever been run in, so
    /// it is tens of megabytes on a machine that has been used for a while. Reading and parsing
    /// that on the main actor is a hitch on the one window in the app whose whole job is to feel
    /// like a welcome. Nothing that comes back is kept: `BridgeUserRegistration` looks at one
    /// table of server names and the bytes are dropped.
    private static func readUserConfig() async -> Data? {
        await Task.detached(priority: .utility) {
            FileManager.default.contents(atPath: BridgeUserRegistration.userConfigPath)
        }.value
    }
}
