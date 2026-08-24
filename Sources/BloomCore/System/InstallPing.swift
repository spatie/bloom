import Foundation

/// The one thing Bloom ever says about itself to a server: that this copy exists, roughly once a
/// day, in five fields.
///
/// Bloom is distributed outside the App Store, so nothing else in the app can answer "how many
/// people run this, and which versions are they on". The updater deliberately cannot answer it
/// either: the appcast is meant to stay a static, cacheable file behind a CDN, and counting
/// installs off the back of it would turn every cache hit into a lost install and every cache miss
/// into a request that has to be logged. So the count is its own small POST instead, and this type
/// owns everything about it that is a judgement rather than a passthrough: what goes in the body,
/// what may never go in it, when it is due, where the token lives, and which builds are allowed to
/// send at all.
///
/// In the core rather than in the app target for the reason `SleepPrevention` and `SoftwareUpdate`
/// are: the whole of it is decidable without a network, and every one of those decisions is the
/// kind that is worth pinning in a test.
///
/// **What is in the body, and nothing else.** An install token, the app version, the macOS
/// version, which coding agent Bloom runs, and the appearance setting. `Payload` has five stored
/// properties and no dictionary, so there is no shape of this type that carries a sixth fact, and
/// every one of the five is either an enum or a string that has been checked against the pattern
/// the endpoint validates it with.
///
/// **What is deliberately absent.** No path, no repository, no branch, no workspace or project
/// name, no prompt, no diff, no hostname, no username, no serial number, no hardware identifier,
/// no credential, and nothing read out of `~/.claude.json` or `~/.codex/auth.json`. Those two
/// files hold live tokens; the ping never opens them. "Which AI" is answered by whether the CLI
/// resolves on `PATH`, which is a fact about the machine's `PATH` and not about an account.
///
/// **The endpoint's rules are its own.** It validates strictly and fails a whole request rather
/// than coercing a field, so the patterns it enforces are restated here and everything is checked
/// against them before it is sent. See `Payload`.
public enum InstallPing {
    // MARK: - Where the state lives

    /// The opt-out switch, in the app's own defaults domain.
    public static let settingKey = "installPing.isEnabled"

    /// The install token. See `installToken(in:)` for why it lives in `UserDefaults` and not in
    /// the keychain.
    public static let tokenKey = "installPing.token"

    /// When this copy of Bloom first ran. See `firstSeenAt(in:now:)`.
    public static let firstSeenKey = "installPing.firstSeenAt"

    /// When the last ping the server handled was sent. See `isDue(firstSeenAt:lastSentAt:now:)`.
    public static let lastSentKey = "installPing.lastSentAt"

    /// On unless it is turned off.
    ///
    /// The trade is stated in the switch's own words rather than hidden behind a default: five
    /// fields, none of which describes the user or their work, against a number that is the only
    /// way anyone finds out whether a release broke launching for a whole macOS version. A count
    /// that only the people who go looking for a switch contribute to is not a count of anything,
    /// so an opt-in default would be a way of shipping this feature without shipping it.
    ///
    /// It is a real switch rather than a courtesy, and it is what the whole thing rests on: the
    /// server keeps no IP address, the privacy page names these five fields, and a visible toggle
    /// in the app is the part that makes that a choice rather than an announcement. Nothing is
    /// sent before it has been there to find, either. See `firstLaunchGrace`.
    ///
    /// Stated once, here, and read by every binding. An `@AppStorage` literal that disagreed with
    /// the registered default is exactly how the menu bar switch once drew off while the item it
    /// controls was plainly in the menu bar.
    public static let isOnByDefault = true

    // MARK: - Where it goes

    /// The endpoint, as agreed with the application that serves it. A real URL rather than a
    /// placeholder, because unlike the appcast this is a host Spatie owns and a path that exists.
    public static let defaultEndpoint = "https://runbloom.app/api/install-reports"

    /// Points a build at a different endpoint, for developing against a local server.
    ///
    /// The same kind of development affordance as `BLOOM_DB_PATH`: it exists so that working on
    /// this feature never has to put a row in the real table. It is also the only way a build made
    /// on this machine can ping at all. See `endpoint(buildChannel:masterCommit:environment:)`.
    public static let endpointVariable = "BLOOM_PING_URL"

    /// Where this build may send, if it may send at all.
    ///
    /// A build made by `Tools/build.sh` without a version stamped on it is a working copy of the source
    /// tree, and the copy `Tools/master.sh` installs is somebody's own build of a commit. Neither is an
    /// install of a release, and counting either would mean the number is mostly the machines of
    /// the people writing the app. `SoftwareUpdate.availability` refuses to update those same two
    /// cases, for a different reason, off the same two Info.plist keys; this reads them as strings
    /// so the rule can be tested without a bundle.
    ///
    /// A local build with `BLOOM_PING_URL` set does send, to whatever that names. That is the
    /// combination that makes this feature developable, and it is also what makes it impossible
    /// for a development build to reach `runbloom.app` by accident: no override, no ping.
    public static func endpoint(
        buildChannel: String?,
        masterCommit: String?,
        environment: [String: String]
    ) -> URL? {
        let override = environment[endpointVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let override, !override.isEmpty {
            return validEndpoint(override)
        }

        guard masterCommit?.isEmpty != false else { return nil }
        guard buildChannel == releaseChannel else { return nil }

        return validEndpoint(defaultEndpoint)
    }

    /// The value `Tools/build.sh` writes into `BloomBuildChannel` for a build that was given a version.
    /// The same string `SoftwareUpdate.releaseChannel` carries, kept here as well so this rule can
    /// be read and tested without reaching into the updater.
    static let releaseChannel = "release"

    /// http and https only, and a host is required. A `file:` or `data:` URL in that environment
    /// variable would otherwise be a way to make the app write a body somewhere local.
    private static func validEndpoint(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - When it is due

    /// How long after this copy first ran before it may send anything at all.
    ///
    /// A day, and it exists for one reason: the switch has to have been findable before the first
    /// thing is sent. Bloom has no onboarding and asks nothing on first launch, which is the right
    /// shape for an app somebody opened to get work done, but it does mean the only way the
    /// setting can be seen is by opening Settings and reading it. So the first launch sends
    /// nothing, and neither does any launch in the first day. Anybody who opens Settings on the
    /// day they install Bloom and turns this off is never counted at all, not even once.
    ///
    /// The cost is that a copy installed and deleted the same day is never counted, which is a
    /// fair price and arguably the correct answer anyway.
    public static let firstLaunchGrace: TimeInterval = 24 * 60 * 60

    /// How long a ping is good for.
    ///
    /// Under a day on purpose. With exactly 24 hours, somebody who opens Bloom at nine, works for
    /// an hour and quits is a minute short of due on every second morning, and the count of a
    /// daily user comes out as five days a week. Twenty hours cannot skip a day like that, and the
    /// most it can produce is a second ping inside one calendar day for a machine that is left
    /// running, which costs one row and no accuracy: the receiving end counts distinct tokens per
    /// day, not rows. It is also comfortably inside the endpoint's throttle of six an hour.
    public static let interval: TimeInterval = 20 * 60 * 60

    /// How often the running app re-asks the question. See `InstallPingService` for why this is a
    /// poll rather than a scheduled timer.
    public static let recheckInterval: TimeInterval = 60 * 60

    /// How long after launch the first check happens.
    ///
    /// Launch is the one moment the app is doing several things that matter, and this is the
    /// thing that matters least. A minute puts it well clear of the window appearing, the store
    /// opening and the first workspace being read, and nothing about it is time critical.
    public static let launchDelay: TimeInterval = 60

    /// Whether a ping may be sent now.
    ///
    /// Measured against two stored instants rather than counted by a timer, which is the whole
    /// point. A timer only fires while the app is open, so an app quit for a week would either
    /// send nothing or, with a naive catch-up, send seven times when it came back. Stored instants
    /// answer both: quit for a week is one ping on the next launch, and a Mac asleep at the moment
    /// one was due is one ping shortly after it wakes, because the next check compares wall clock
    /// times rather than asking whether anything happened while it was asleep.
    ///
    /// A last-sent date in the future means the clock moved backwards under us, which would
    /// otherwise silence the ping until the calendar caught up.
    public static func isDue(firstSeenAt: Date?, lastSentAt: Date?, now: Date) -> Bool {
        // No first-seen date means this launch is recording it, so this is the first run and the
        // grace period has not even started.
        guard let firstSeenAt else { return false }
        guard now.timeIntervalSince(firstSeenAt) >= firstLaunchGrace else { return false }

        guard let lastSentAt else { return true }
        if lastSentAt > now { return true }
        return now.timeIntervalSince(lastSentAt) >= interval
    }

    // MARK: - The token

    /// The install token, generated on first use and kept from then on.
    ///
    /// A v4 UUID: random, meaningless on its own, and derived from nothing. Deliberately not the
    /// hardware UUID, not the serial number, not the MAC address, not a hash of the home directory
    /// and not anything else that two applications could arrive at independently. The only thing
    /// it can ever be joined against is another ping from the same copy of Bloom, which is exactly
    /// as much as counting installs needs. Its 36 characters sit inside the 16 to 64 the endpoint
    /// accepts.
    ///
    /// **It lives in `UserDefaults`, not the keychain**, and that is a choice with a consequence.
    /// The defaults domain survives what this has to survive: quitting, updating in place, and
    /// Sparkle replacing the bundle, because none of those touch
    /// `~/Library/Preferences/be.spatie.bloom.plist`. It does not survive somebody deleting Bloom's
    /// data, and that is the right way round for an anonymous counter: removing the app should
    /// mean the app forgets you, and a reinstall afterwards is honestly a new install. A keychain
    /// item would outlive the uninstall, which makes the number very slightly more accurate and
    /// leaves a thing behind on the user's disk that they did not ask for and cannot easily find.
    /// For a count, that trade is not close.
    ///
    /// So the number means "copies of Bloom whose preferences have survived", not "people". Two
    /// Macs are two installs, a wiped preferences file is a new install, and a Mac migrated to a
    /// new machine carries its token across. Anyone reading the graph should read it that way.
    @discardableResult
    public static func installToken(in defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: tokenKey)
        if let stored, isWellFormedToken(stored) { return stored }

        let fresh = newToken()
        defaults.set(fresh, forKey: tokenKey)
        return fresh
    }

    public static func newToken() -> String {
        UUID().uuidString
    }

    /// A stored value that is not a UUID was not written by this code, so it is replaced rather
    /// than sent. That is what keeps anything a person may have typed into that key out of the
    /// body, and it is also what guarantees the token matches `tokenPattern`.
    public static func isWellFormedToken(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    // MARK: - Reading and writing the rest of the state

    /// Correct whether or not the default has been registered, because the core tests read a
    /// throwaway domain that nothing registers into. `bool(forKey:)` alone would answer false on a
    /// fresh domain no matter what this type says the default is.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? isOnByDefault
    }

    /// When this copy first ran, recording it if this is that moment.
    ///
    /// A stored date in the future is rewritten rather than trusted: a clock that was briefly set
    /// years ahead would otherwise hold the grace period open forever, and silence is meant to be
    /// the cost of a bad minute rather than of a bad clock.
    @discardableResult
    public static func firstSeenAt(in defaults: UserDefaults = .standard, now: Date = Date()) -> Date {
        if let stored = defaults.object(forKey: firstSeenKey) as? Date, stored <= now {
            return stored
        }

        defaults.set(now, forKey: firstSeenKey)
        return now
    }

    public static func storedFirstSeenAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: firstSeenKey) as? Date
    }

    public static func lastSentAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastSentKey) as? Date
    }

    /// Written after a ping the server took, and after one it refused for good. A refusal that
    /// will happen again is not worth asking about every hour. See `Outcome`.
    public static func recordSend(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastSentKey)
    }

    // MARK: - The theme

    /// The appearance setting, as one of three known values.
    ///
    /// Not a new preference. `AppearanceSettingsView` owns the picker and writes exactly these
    /// three strings under this key; this is a typed reading of it, so that a hand-edited default
    /// cannot put free text in the body. All three already match the endpoint's `namePattern`.
    public enum Theme: String, Sendable, Equatable, CaseIterable, Codable {
        case system
        case light
        case dark

        /// The key `AppearanceSettingsView` writes.
        public static let defaultsKey = "appearance"

        /// Anything unrecognised reads as the default the picker itself starts on.
        public init(defaultsValue: String?) {
            self = Theme(rawValue: defaultsValue ?? "") ?? .system
        }

        public init(in defaults: UserDefaults = .standard) {
            self.init(defaultsValue: defaults.string(forKey: Theme.defaultsKey))
        }
    }

    // MARK: - Which agent

    /// The wire name for an agent backend. Lowercase and stable, because it is stored and shown
    /// verbatim by the receiving end: changing one of these renames a bar on somebody's chart and
    /// splits its history in two.
    public static func wireName(_ kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .openCode: "opencode"
        }
    }

    /// What is sent when Bloom cannot run a turn at all on this machine, because the CLI it drives
    /// is not installed. A real answer rather than an omission: an install that cannot run
    /// anything is the most interesting install in the table.
    public static let noAgent = "none"

    /// Which agents this copy of Bloom can actually run turns with, given what is installed.
    ///
    /// Still one value, because the endpoint stores one, but no longer one agent: a machine with
    /// both CLIs sends `claude_codex`. That is the day this comment used to describe, and nothing
    /// on either side had to change for it, because the endpoint stores an unfamiliar value
    /// verbatim rather than dropping it and the joined name still matches its `namePattern`.
    ///
    /// Deliberately not "whatever CLIs happen to be on the machine". Having `cursor-agent` on
    /// `PATH` is not Bloom using Cursor, so only backends `AgentKind.canRunWorkspaces` admits to
    /// are counted. In `AgentKind.allCases` order, so the same machine sends the same name every
    /// day rather than one that depends on how the array came back.
    public static func agentName(installed: [AgentKind]) -> String {
        let runnable = AgentKind.allCases.filter { $0.canRunWorkspaces && installed.contains($0) }
        guard !runnable.isEmpty else { return noAgent }
        return runnable.map(wireName).joined(separator: "_")
    }

    // MARK: - The body

    /// Everything that is sent, and the only thing that is sent.
    ///
    /// Five stored properties, each one checked against the pattern the endpoint validates it
    /// with. That check is not politeness: the endpoint fails the whole request rather than
    /// coercing a field, and a 422 is not worth retrying, so a body that would be refused is a
    /// day's count thrown away. Anything that does not match is replaced by a value that does and
    /// that obviously means "we could not tell", rather than by something plausible.
    ///
    /// Adding a field here is the only way to change what leaves the machine, which is the
    /// property the whole design is arranged around.
    public struct Payload: Sendable, Equatable, Encodable {
        /// The install token. See `installToken(in:)`.
        public let token: String

        /// `CFBundleShortVersionString`, e.g. `0.4.0`.
        public let appVersion: String

        /// `26.1.0`. Three numbers, which is all `ProcessInfo` gives and all anybody needs to know
        /// whether a crash is confined to one macOS release.
        public let macOSVersion: String

        /// Which coding agent Bloom runs here. See `agentName(installed:)`.
        public let agent: String

        /// The appearance setting.
        public let theme: Theme

        public init(
            token: String,
            appVersion: String,
            macOSVersion: String,
            agent: String,
            theme: Theme
        ) {
            self.token = InstallPing.matches(token, InstallPing.tokenPattern) ? token : InstallPing.newToken()
            self.appVersion = InstallPing.checked(appVersion, InstallPing.appVersionPattern, or: InstallPing.unknownVersion)
            self.macOSVersion = InstallPing.checked(macOSVersion, InstallPing.systemVersionPattern, or: InstallPing.unknownVersion)
            self.agent = InstallPing.checked(agent, InstallPing.namePattern, or: InstallPing.unknownName)
            self.theme = theme
        }

        /// snake_case, because the application receiving this is a Laravel app and this is the
        /// shape it validates. The names are part of the contract with it and must not drift.
        enum CodingKeys: String, CodingKey {
            case token
            case appVersion = "app_version"
            case macOSVersion = "macos_version"
            case agent
            case theme
        }
    }

    // MARK: - The endpoint's own rules, restated

    /// A UUID or a ULID both fit.
    public static let tokenPattern = #"^[A-Za-z0-9-]{16,64}$"#

    /// `1.2.0`, `1.2.0.412` and `1.3.0-beta.2` all pass.
    public static let appVersionPattern = #"^\d{1,4}(\.\d{1,4}){0,3}(-[A-Za-z0-9.]{1,16})?$"#

    public static let systemVersionPattern = #"^\d{1,3}(\.\d{1,3}){0,2}$"#

    /// What `agent` and `theme` have to look like.
    public static let namePattern = #"^[a-z][a-z0-9_-]{0,31}$"#

    /// Sent in place of a version that does not look like one. Version shaped, and obviously not a
    /// version anybody released.
    public static let unknownVersion = "0.0.0"

    /// Sent in place of a name that does not look like one.
    public static let unknownName = "unknown"

    /// The endpoint refuses a body over this, and refuses it for good. Ours is around 150 bytes,
    /// which is worth knowing if a field is ever added.
    public static let maximumBodyBytes = 2_048

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func checked(_ raw: String, _ pattern: String, or fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches(trimmed, pattern) ? trimmed : fallback
    }

    /// `26.1.0` from the three numbers `ProcessInfo` reports, each one held inside what the
    /// endpoint accepts.
    public static func macOSVersion(major: Int, minor: Int, patch: Int) -> String {
        let clamped = [major, minor, patch].map { min(max($0, 0), 999) }
        return clamped.map(String.init).joined(separator: ".")
    }

    /// The JSON body. Sorted keys so the same facts always produce the same bytes, which is what
    /// makes it assertable.
    ///
    /// `reported_at` is deliberately not sent, though the endpoint would accept it. It orders by
    /// its own receipt time whatever the client claims, so the field would buy nothing and would
    /// be one more thing leaving the machine.
    public static func body(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// The whole request, built here so the headers are pinned by the same tests as the body.
    ///
    /// Short timeout, no cookies, no cache. A ping that has not completed in ten seconds has
    /// missed its turn and will be asked again in an hour, and there is nothing here worth holding
    /// a connection open for.
    public static func request(to endpoint: URL, payload: Payload) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = try body(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Stated rather than left to the system, whose default carries the CFNetwork and Darwin
        // build numbers along with it.
        request.setValue("Bloom/\(payload.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    // MARK: - What the answer means

    /// What to do about the reply, which is never more than "write down the date or do not".
    public enum Outcome: Sendable, Equatable {
        /// A 2xx. The endpoint answers 202 with an empty body.
        case accepted

        /// A refusal that will happen again to the same body: 422 because a field did not
        /// validate, 413 because it was too long, or any other 4xx. Recorded as though it had been
        /// accepted, so it is retried in a day rather than every hour. A day is long enough for an
        /// update to have fixed whatever it was.
        case refused

        /// A 429. Nothing is written down, and the next attempt waits at least as long as the
        /// server asked for.
        case throttled(retryAfter: TimeInterval?)

        /// No answer, or a 5xx. The server may simply be down, so the day is not spent: the next
        /// hourly question asks again.
        case failed
    }

    public static func outcome(statusCode: Int, retryAfter: String? = nil, now: Date = Date()) -> Outcome {
        switch statusCode {
        case 200..<300: .accepted
        case 429: .throttled(retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 400..<500: .refused
        default: .failed
        }
    }

    /// Whether this outcome ends the day's attempt.
    public static func closesTheDay(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .accepted, .refused: true
        case .throttled, .failed: false
        }
    }

    /// How long to wait before asking again. Never shorter than the hourly recheck, so a server
    /// asking for a five second wait cannot turn this into a busy loop.
    public static func delay(after outcome: Outcome) -> TimeInterval {
        switch outcome {
        case .throttled(let retryAfter): max(recheckInterval, retryAfter ?? recheckInterval)
        case .accepted, .refused, .failed: recheckInterval
        }
    }

    /// `Retry-After`, in either of the two forms the header is allowed to take: a number of
    /// seconds, or an HTTP date.
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        // Built here rather than kept around: this runs once in a blue moon, and a shared
        // `DateFormatter` is not something to hand between tasks.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    // MARK: - The Settings row

    public static let settingTitle = "Send an anonymous daily ping"

    /// Names the five fields, in the order they are in the body and in the same words the privacy
    /// page uses. A switch about sending data that does not say what it sends is asking for trust
    /// it has not earned.
    public static let settingDetail =
        "Once a day Bloom sends a random install token, its own version, your macOS version, which coding agent it runs, and your appearance setting. Nothing else."

    /// The part that answers "what about my work", which is the actual question behind the switch.
    public static let settingFooter =
        "The token is a random number generated on this Mac and is not derived from you or your hardware. No project, repository, branch, path, prompt or account detail is ever included, and your IP address is not stored. This is how Bloom's author knows how many people use it and which versions to keep supporting."
}
