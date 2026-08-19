import Foundation
import BloomCore

/// Sends the install ping, and does nothing else.
///
/// The rules are all in `InstallPing`, in the core, where they are under test: what is in the
/// body, when it is due, which builds may send at all, where the token lives, and what each answer
/// from the server means. What is left here is the three things that need the running app: reading
/// this bundle's version, asking the machine whether the agent CLI is there, and putting the
/// request on the wire.
///
/// A shared object with a loop of its own rather than a `.task` on a view, because a view's task
/// is cancelled when the view goes away and Bloom keeps running with its window closed. The loop
/// polls rather than schedules: it asks a question about the wall clock every hour, so a Mac that
/// was asleep at the moment a ping came due sends shortly after it wakes, and a Mac that was
/// asleep for a week still sends exactly once.
///
/// **Everything here fails silently.** No alert, no notice, no banner, no retry beyond the next
/// hourly question, and nothing is written down unless the server actually answered. This is the
/// least important thing the app does, and it must never be the reason somebody's launch is slow,
/// their quit is held up or their screen has a dialog on it.
@MainActor
final class InstallPingService {
    static let shared = InstallPingService()

    /// Started once. Unstructured on purpose: it outlives the window, and nothing ever waits on
    /// it, including the quit sequence.
    private var loop: Task<Void, Never>?

    /// Borrowed for one question: which executable paths the user pointed the Agents pane at.
    private weak var app: AppModel?

    /// Ephemeral, so nothing about this request is ever written to a cache or a cookie jar on the
    /// user's disk. `waitsForConnectivity` is off because a request that waits for a network is a
    /// request that outlives the moment it was due, and the next question is only an hour away.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - Starting

    /// Called from `RootView` once the window exists. Idempotent.
    func start(app: AppModel) {
        guard loop == nil else { return }
        self.app = app

        // So the Settings switch and any direct read of the key agree about the default, which is
        // the bug that made the menu bar toggle draw off while the item was in the menu bar.
        SystemDefaults.registerOnce()

        // Records this copy's first run if this is it. Written on every launch rather than only
        // when a ping is due, because it is what the grace period is measured from and the whole
        // point of the grace period is that the first launch sends nothing.
        InstallPing.firstSeenAt()

        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = InstallPing.endpoint(
            buildChannel: Bundle.main.object(forInfoDictionaryKey: SoftwareUpdate.buildChannelKey) as? String,
            masterCommit: Bundle.main.object(forInfoDictionaryKey: SoftwareUpdate.masterCommitKey) as? String,
            environment: environment
        ) else {
            Log.ping.info("No ping: this build has no endpoint to send to.")
            return
        }

        loop = Task { [weak self] in
            // Well clear of the launch. Nothing here is time critical and everything else is.
            try? await Task.sleep(for: .seconds(InstallPing.launchDelay))

            while !Task.isCancelled {
                let outcome = await self?.sendIfDue(to: endpoint)
                let delay = outcome.map(InstallPing.delay(after:)) ?? InstallPing.recheckInterval
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - The one thing it does

    /// Nil when nothing was due, which is almost always.
    @discardableResult
    private func sendIfDue(to endpoint: URL) async -> InstallPing.Outcome? {
        let defaults = UserDefaults.standard

        guard InstallPing.isEnabled(in: defaults) else { return nil }
        guard InstallPing.isDue(
            firstSeenAt: InstallPing.storedFirstSeenAt(in: defaults),
            lastSentAt: InstallPing.lastSentAt(in: defaults),
            now: Date()
        ) else { return nil }

        let payload = await currentPayload(token: InstallPing.installToken(in: defaults))
        guard let request = try? InstallPing.request(to: endpoint, payload: payload) else { return nil }

        let outcome = await send(request)

        // Only once the server has answered. A minute of no network must not cost the day, and a
        // refusal that will happen again must not be asked about every hour.
        if InstallPing.closesTheDay(outcome) {
            InstallPing.recordSend(at: Date(), in: defaults)
        }

        return outcome
    }

    /// The five facts, and nothing that is not one of them.
    private func currentPayload(token: String) async -> InstallPing.Payload {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let overrides = await executablePathOverrides()

        // Off the main actor: this stats a handful of directories on `PATH`. It opens no config
        // file and reads no account, which is the whole reason the ping asks `AgentCatalog` this
        // question rather than the one the settings screen asks.
        let installed = await Task.detached(priority: .background) {
            AgentCatalog.installedKinds(overrides: overrides)
        }.value

        return InstallPing.Payload(
            token: token,
            appVersion: version ?? InstallPing.unknownVersion,
            macOSVersion: InstallPing.macOSVersion(
                major: system.majorVersion,
                minor: system.minorVersion,
                patch: system.patchVersion
            ),
            agent: InstallPing.agentName(installed: installed),
            theme: InstallPing.Theme()
        )
    }

    /// The per-agent executable paths the Agents pane stored, so an agent installed somewhere
    /// unusual is seen as present rather than missing. Empty when the store is not open yet, which
    /// only costs the accuracy of a custom path on the first ping after a launch.
    private func executablePathOverrides() async -> [AgentKind: String] {
        guard let store = app?.store else { return [:] }

        var found: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            guard let value = try? await store.setting(AgentCatalog.executablePathSettingKey(kind)) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { found[kind] = trimmed }
        }
        return found
    }

    /// What the server said, or that it said nothing. Every outcome is silent to the user.
    private func send(_ request: URLRequest) async -> InstallPing.Outcome {
        do {
            let (_, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }

            let outcome = InstallPing.outcome(
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
            if outcome != .accepted {
                Log.ping.debug("Ping answered \(http.statusCode, privacy: .public)")
            }
            return outcome
        } catch {
            Log.ping.debug("Ping not sent: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
