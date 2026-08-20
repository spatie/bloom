import Foundation
import Testing
@testable import BloomCore

/// The ping is the only thing Bloom sends about itself, so what is in it, when it goes, where it
/// may go and what each answer means are all pinned here rather than left to a reading of the app
/// target. The endpoint validates strictly and refuses a whole request rather than coercing a
/// field, so the patterns below are the contract with it.
@Suite("Install ping")
struct InstallPingTests {
    private func payload(
        token: String = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        appVersion: String = "0.4.0",
        macOSVersion: String = "26.1.0",
        agent: String = "claude",
        theme: InstallPing.Theme = .system
    ) -> InstallPing.Payload {
        InstallPing.Payload(
            token: token,
            appVersion: appVersion,
            macOSVersion: macOSVersion,
            agent: agent,
            theme: theme
        )
    }

    private func object(_ payload: InstallPing.Payload) throws -> [String: Any] {
        let data = try InstallPing.body(payload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A throwaway defaults domain, so no test ever reads or writes the domain the app uses.
    private func scratchDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "bloom.test.ping.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func clean(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: - What is in the body

    @Test("sends five fields and no sixth")
    func bodyHasExactlyTheAgreedKeys() throws {
        let json = try object(payload())

        #expect(Set(json.keys) == ["token", "app_version", "macos_version", "agent", "theme"])
    }

    @Test("sends the five facts as the endpoint expects them")
    func bodyValues() throws {
        let json = try object(payload(agent: "codex", theme: .dark))

        #expect(json["token"] as? String == "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        #expect(json["app_version"] as? String == "0.4.0")
        #expect(json["macos_version"] as? String == "26.1.0")
        #expect(json["agent"] as? String == "codex")
        #expect(json["theme"] as? String == "dark")
    }

    /// The body is built from a struct with five stored properties, so the only way a path, a
    /// branch or a prompt could reach it is by somebody adding a field. This is the test that
    /// fails when they do.
    @Test("cannot carry anything about the user or their work")
    func bodyCarriesNothingElse() throws {
        let data = try InstallPing.body(payload(theme: .light))
        let text = try #require(String(data: data, encoding: .utf8))

        for forbidden in ["/Users", "branch", "repo", "prompt", "path", "host", "email", "name"] {
            #expect(!text.contains(forbidden), "the body mentioned \(forbidden)")
        }
    }

    @Test("stays far inside the size the endpoint accepts")
    func bodyIsSmall() throws {
        let data = try InstallPing.body(payload(agent: "unknown", theme: .dark))

        #expect(data.count < 300)
        #expect(data.count < InstallPing.maximumBodyBytes)
    }

    // MARK: - Every field matches what the endpoint validates

    @Test("sends a token of the shape the endpoint accepts")
    func tokenMatchesThePattern() {
        #expect(InstallPing.matches(InstallPing.newToken(), InstallPing.tokenPattern))
    }

    @Test("replaces a token that would be refused")
    func tokenIsReplacedRatherThanSent() throws {
        let json = try object(payload(token: "not a token"))
        let sent = try #require(json["token"] as? String)

        #expect(sent != "not a token")
        #expect(InstallPing.matches(sent, InstallPing.tokenPattern))
    }

    @Test("sends a version only when it looks like one")
    func versionsAreChecked() throws {
        #expect(try object(payload(appVersion: "1.2.0"))["app_version"] as? String == "1.2.0")
        #expect(try object(payload(appVersion: "1.2.0.412"))["app_version"] as? String == "1.2.0.412")
        #expect(try object(payload(appVersion: "1.3.0-beta.2"))["app_version"] as? String == "1.3.0-beta.2")
        // A build number in parentheses is not a version the endpoint takes, and a 422 is not
        // worth a day's count.
        #expect(try object(payload(appVersion: "0.4.0 (17)"))["app_version"] as? String == "0.0.0")
        #expect(try object(payload(appVersion: ""))["app_version"] as? String == "0.0.0")
        #expect(try object(payload(macOSVersion: "not a version"))["macos_version"] as? String == "0.0.0")
    }

    @Test("says the macOS version in three numbers")
    func macOSVersionIsThreeNumbers() {
        #expect(InstallPing.macOSVersion(major: 26, minor: 1, patch: 0) == "26.1.0")
        #expect(InstallPing.macOSVersion(major: 15, minor: 0, patch: 2) == "15.0.2")
        #expect(InstallPing.matches(InstallPing.macOSVersion(major: 26, minor: 1, patch: 0), InstallPing.systemVersionPattern))
        // Nothing `ProcessInfo` reports looks like this, and the endpoint would refuse it if it did.
        #expect(InstallPing.macOSVersion(major: 40_000, minor: -3, patch: 0) == "999.0.0")
    }

    @Test("sends an agent name only when it looks like one")
    func agentNameIsChecked() throws {
        #expect(try object(payload(agent: "claude"))["agent"] as? String == "claude")
        #expect(try object(payload(agent: "Claude Code"))["agent"] as? String == "unknown")
        #expect(try object(payload(agent: ""))["agent"] as? String == "unknown")
    }

    @Test("every theme the picker offers is a name the endpoint takes")
    func themesMatchThePattern() {
        for theme in InstallPing.Theme.allCases {
            #expect(InstallPing.matches(theme.rawValue, InstallPing.namePattern))
        }
    }

    @Test("every agent has a lowercase wire name")
    func wireNamesMatchThePattern() {
        for kind in AgentKind.allCases {
            #expect(InstallPing.matches(InstallPing.wireName(kind), InstallPing.namePattern))
        }
        #expect(InstallPing.wireName(.claudeCode) == "claude")
        #expect(InstallPing.wireName(.openCode) == "opencode")
        #expect(InstallPing.matches(InstallPing.noAgent, InstallPing.namePattern))
    }

    // MARK: - Which agent is reported

    @Test("names the agents Bloom can actually run")
    func agentIsTheOneBloomRuns() {
        #expect(InstallPing.agentName(installed: [.claudeCode]) == "claude")
        #expect(InstallPing.agentName(installed: [.codex]) == "codex")
        // Both installed is a real and interesting answer, not a choice between them.
        #expect(InstallPing.agentName(installed: [.claudeCode, .codex]) == "claude_codex")
        // Always in `allCases` order, so the same machine sends the same name every day.
        #expect(InstallPing.agentName(installed: [.codex, .claudeCode]) == "claude_codex")
        // And still a name the endpoint accepts, which is the only reason `_` is the separator.
        #expect(InstallPing.matches("claude_codex", InstallPing.namePattern))
    }

    /// Having `cursor-agent` on `PATH` is not Bloom using Cursor.
    @Test("does not claim an agent Bloom cannot run a turn with")
    func otherCLIsAreNotTheAgent() {
        #expect(InstallPing.agentName(installed: [.cursor, .openCode]) == "none")
        #expect(InstallPing.agentName(installed: [.codex, .cursor, .openCode]) == "codex")
    }

    @Test("says so when nothing is installed to run")
    func noAgentAtAll() {
        #expect(InstallPing.agentName(installed: []) == "none")
    }

    // MARK: - The request

    @Test("posts JSON and names itself")
    func requestShape() throws {
        let url = try #require(URL(string: InstallPing.defaultEndpoint))
        let request = try InstallPing.request(to: url, payload: payload())

        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Bloom/0.4.0")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 10)
        #expect(request.httpBody == (try InstallPing.body(payload())))
    }

    // MARK: - What the answer means

    @Test("takes a 202 as the day being done")
    func acceptance() {
        #expect(InstallPing.outcome(statusCode: 202) == .accepted)
        #expect(InstallPing.outcome(statusCode: 200) == .accepted)
        #expect(InstallPing.closesTheDay(.accepted))
    }

    /// A body the endpoint refuses will be refused again, so it is not asked about again today.
    @Test("does not retry a refusal today")
    func refusals() {
        #expect(InstallPing.outcome(statusCode: 422) == .refused)
        #expect(InstallPing.outcome(statusCode: 413) == .refused)
        #expect(InstallPing.outcome(statusCode: 404) == .refused)
        #expect(InstallPing.closesTheDay(.refused))
    }

    @Test("keeps the day open when the server is simply not there")
    func failures() {
        #expect(InstallPing.outcome(statusCode: 500) == .failed)
        #expect(InstallPing.outcome(statusCode: 503) == .failed)
        #expect(!InstallPing.closesTheDay(.failed))
        #expect(!InstallPing.closesTheDay(.throttled(retryAfter: 60)))
    }

    @Test("waits as long as a throttle asks, and never less than an hour")
    func throttling() {
        let now = Date()

        #expect(InstallPing.outcome(statusCode: 429, retryAfter: "120", now: now) == .throttled(retryAfter: 120))
        #expect(InstallPing.delay(after: .throttled(retryAfter: 120)) == InstallPing.recheckInterval)
        #expect(InstallPing.delay(after: .throttled(retryAfter: 7_200)) == 7_200)
        #expect(InstallPing.delay(after: .throttled(retryAfter: nil)) == InstallPing.recheckInterval)
        #expect(InstallPing.delay(after: .accepted) == InstallPing.recheckInterval)
    }

    @Test("reads Retry-After as seconds or as a date")
    func retryAfterHeader() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-19T09:00:00Z"))

        #expect(InstallPing.retryAfterSeconds("90", now: now) == 90)
        #expect(InstallPing.retryAfterSeconds("Wed, 19 Aug 2026 09:30:00 GMT", now: now) == 1_800)
        // A date that has already passed is not a wait.
        #expect(InstallPing.retryAfterSeconds("Wed, 19 Aug 2026 08:30:00 GMT", now: now) == 0)
        #expect(InstallPing.retryAfterSeconds(nil, now: now) == nil)
        #expect(InstallPing.retryAfterSeconds("soon", now: now) == nil)
    }

    // MARK: - The first launch

    /// The switch has to have been findable before anything is sent, and Bloom asks nothing on
    /// first launch, so the first day is silent.
    @Test("sends nothing on the very first launch")
    func firstLaunchIsSilent() {
        let now = Date()

        #expect(!InstallPing.isDue(firstSeenAt: nil, lastSentAt: nil, now: now))
        #expect(!InstallPing.isDue(firstSeenAt: now, lastSentAt: nil, now: now))
        #expect(!InstallPing.isDue(
            firstSeenAt: now.addingTimeInterval(-InstallPing.firstLaunchGrace + 60),
            lastSentAt: nil,
            now: now
        ))
    }

    @Test("sends for the first time a day after it was installed")
    func firstPingAfterTheGrace() {
        let now = Date()

        #expect(InstallPing.isDue(
            firstSeenAt: now.addingTimeInterval(-InstallPing.firstLaunchGrace),
            lastSentAt: nil,
            now: now
        ))
    }

    @Test("records the first run once and keeps it")
    func firstSeenIsRecordedOnce() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        let installed = Date().addingTimeInterval(-3_600)
        #expect(InstallPing.storedFirstSeenAt(in: defaults) == nil)

        let first = InstallPing.firstSeenAt(in: defaults, now: installed)
        let second = InstallPing.firstSeenAt(in: defaults, now: installed.addingTimeInterval(600))

        #expect(first == installed)
        #expect(second == installed)
    }

    /// A clock briefly set years ahead would otherwise hold the grace period open forever.
    @Test("does not let a bad clock silence it forever")
    func firstSeenInTheFutureIsRewritten() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        let now = Date()
        defaults.set(now.addingTimeInterval(365 * 24 * 60 * 60), forKey: InstallPing.firstSeenKey)

        #expect(InstallPing.firstSeenAt(in: defaults, now: now) == now)
    }

    // MARK: - When it is due

    private func due(lastSentAt: Date?, now: Date) -> Bool {
        InstallPing.isDue(
            firstSeenAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            lastSentAt: lastSentAt,
            now: now
        )
    }

    @Test("is due when it has never been sent")
    func dueOnceTheGraceHasPassed() {
        #expect(due(lastSentAt: nil, now: Date()))
    }

    @Test("is not due again on the next launch the same day")
    func notDueTwiceInADay() {
        let now = Date()
        #expect(!due(lastSentAt: now, now: now))
        #expect(!due(lastSentAt: now.addingTimeInterval(-3_600), now: now))
        #expect(!due(lastSentAt: now.addingTimeInterval(-InstallPing.interval + 1), now: now))
    }

    @Test("comes due again after the interval")
    func dueAfterTheInterval() {
        let now = Date()
        #expect(due(lastSentAt: now.addingTimeInterval(-InstallPing.interval), now: now))
    }

    /// Quit for a week is one ping when the app comes back, not seven.
    @Test("sends once after a week of not launching")
    func aWeekAwayIsOnePing() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        let launch = Date()
        InstallPing.firstSeenAt(in: defaults, now: launch.addingTimeInterval(-30 * 24 * 60 * 60))
        InstallPing.recordSend(at: launch.addingTimeInterval(-7 * 24 * 60 * 60), in: defaults)

        func isDueNow(_ now: Date) -> Bool {
            InstallPing.isDue(
                firstSeenAt: InstallPing.storedFirstSeenAt(in: defaults),
                lastSentAt: InstallPing.lastSentAt(in: defaults),
                now: now
            )
        }

        #expect(isDueNow(launch))
        InstallPing.recordSend(at: launch, in: defaults)
        #expect(!isDueNow(launch))
        #expect(!isDueNow(launch.addingTimeInterval(InstallPing.recheckInterval)))
    }

    /// A Mac asleep when a ping was due sends shortly after it wakes, because the question is
    /// asked against the clock rather than against whether a timer got to fire.
    @Test("sends after a sleep that ran through the moment it was due")
    func sleepDoesNotSkipADay() {
        let due = Date()
        let sentBefore = due.addingTimeInterval(-InstallPing.interval - 60)
        let wokeUp = due.addingTimeInterval(8 * 60 * 60)

        #expect(self.due(lastSentAt: sentBefore, now: wokeUp))
    }

    @Test("is due when the clock has moved backwards")
    func clockRollback() {
        let now = Date()
        #expect(due(lastSentAt: now.addingTimeInterval(600), now: now))
    }

    @Test("asks again more often than it sends")
    func recheckIsShorterThanTheInterval() {
        #expect(InstallPing.recheckInterval < InstallPing.interval)
        #expect(InstallPing.interval < 24 * 60 * 60)
        #expect(InstallPing.launchDelay > 0)
        // Six an hour is the endpoint's throttle, and this is nowhere near it.
        #expect(InstallPing.interval > 3 * InstallPing.recheckInterval)
    }

    // MARK: - The token

    @Test("keeps the same token across launches")
    func tokenIsStable() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        let first = InstallPing.installToken(in: defaults)
        let second = InstallPing.installToken(in: defaults)

        #expect(first == second)
        #expect(defaults.string(forKey: InstallPing.tokenKey) == first)
    }

    @Test("generates a random token that is derived from nothing")
    func tokenIsRandom() {
        let (nameA, a) = scratchDefaults()
        let (nameB, b) = scratchDefaults()
        defer { clean(nameA); clean(nameB) }

        let one = InstallPing.installToken(in: a)
        let other = InstallPing.installToken(in: b)

        #expect(one != other)
        #expect(InstallPing.isWellFormedToken(one))
        #expect(UUID(uuidString: one) != nil)
    }

    @Test("replaces a stored value that it did not write")
    func tokenIsValidated() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        defaults.set("/Users/freek/dev/code/Baton", forKey: InstallPing.tokenKey)
        let token = InstallPing.installToken(in: defaults)

        #expect(token != "/Users/freek/dev/code/Baton")
        #expect(InstallPing.isWellFormedToken(token))
    }

    // MARK: - The switch

    @Test("is on before anybody has touched the switch")
    func defaultsOn() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        #expect(InstallPing.isOnByDefault)
        #expect(InstallPing.isEnabled(in: defaults))
    }

    @Test("stays off once it has been turned off")
    func respectsTheSwitch() {
        let (name, defaults) = scratchDefaults()
        defer { clean(name) }

        defaults.set(false, forKey: InstallPing.settingKey)
        #expect(!InstallPing.isEnabled(in: defaults))

        defaults.set(true, forKey: InstallPing.settingKey)
        #expect(InstallPing.isEnabled(in: defaults))
    }

    /// The same five things the privacy page names, in the switch itself.
    @Test("says in the switch itself what leaves the machine")
    func copyDescribesThePayload() {
        for word in ["install token", "version", "macOS", "coding agent", "appearance"] {
            #expect(InstallPing.settingDetail.localizedCaseInsensitiveContains(word))
        }
        #expect(InstallPing.settingFooter.contains("random"))
        #expect(InstallPing.settingFooter.contains("repository"))
        #expect(InstallPing.settingFooter.contains("IP address"))
    }

    // MARK: - Which builds may send

    private func endpoint(
        channel: String? = nil,
        masterCommit: String? = nil,
        environment: [String: String] = [:]
    ) -> URL? {
        InstallPing.endpoint(
            buildChannel: channel,
            masterCommit: masterCommit,
            environment: environment
        )
    }

    @Test("a release build pings the real endpoint")
    func releaseBuildPings() {
        #expect(endpoint(channel: "release")?.absoluteString == InstallPing.defaultEndpoint)
    }

    @Test("a build made from source pings nothing at all")
    func localBuildIsSilent() {
        #expect(endpoint(channel: nil) == nil)
        #expect(endpoint(channel: "local") == nil)
    }

    /// The copy `master.sh` installs is somebody's own build of a commit, not an install.
    @Test("the master build pings nothing at all")
    func masterBuildIsSilent() {
        #expect(endpoint(channel: "release", masterCommit: "abc1234") == nil)
    }

    @Test("a local endpoint can be named, and is the only way a development build sends")
    func overrideIsHonoured() {
        let local = ["BLOOM_PING_URL": "http://127.0.0.1:8787/api/install-reports"]

        #expect(endpoint(channel: nil, environment: local)?.absoluteString == local["BLOOM_PING_URL"])
        #expect(endpoint(channel: "release", environment: local)?.absoluteString == local["BLOOM_PING_URL"])
    }

    @Test("refuses an endpoint that is not http")
    func overrideMustBeHTTP() {
        #expect(endpoint(environment: ["BLOOM_PING_URL": "file:///tmp/ping.json"]) == nil)
        #expect(endpoint(environment: ["BLOOM_PING_URL": "not a url at all"]) == nil)
        #expect(endpoint(channel: "release", environment: ["BLOOM_PING_URL": "   "])?.absoluteString
            == InstallPing.defaultEndpoint)
    }

    @Test("never reaches for a host nobody agreed to")
    func defaultEndpointIsTheAgreedOne() throws {
        let url = try #require(URL(string: InstallPing.defaultEndpoint))

        #expect(url.scheme == "https")
        #expect(url.host == "runbloom.app")
        #expect(url.path == "/api/install-reports")
    }

    // MARK: - The theme

    @Test("reads the appearance setting the picker writes")
    func themeReadsTheExistingPreference() {
        #expect(InstallPing.Theme.defaultsKey == "appearance")
        #expect(InstallPing.Theme(defaultsValue: "dark") == .dark)
        #expect(InstallPing.Theme(defaultsValue: "light") == .light)
        #expect(InstallPing.Theme(defaultsValue: "system") == .system)
    }

    @Test("reads anything it does not recognise as the default")
    func themeFallsBack() {
        #expect(InstallPing.Theme(defaultsValue: nil) == .system)
        #expect(InstallPing.Theme(defaultsValue: "") == .system)
        #expect(InstallPing.Theme(defaultsValue: "/Users/freek") == .system)
    }
}

/// The one thing the ping asks about the machine, kept away from the detection that reads account
/// files.
@Suite("Installed agent kinds")
struct InstalledAgentKindsTests {
    @Test("counts an agent the user pointed at a path of their own")
    func honoursAnOverride() {
        let found = AgentCatalog.installedKinds(overrides: [.codex: "/bin/ls"])

        #expect(found.contains(.codex))
    }

    @Test("does not count an override that points at nothing")
    func ignoresABrokenOverride() {
        let found = AgentCatalog.installedKinds(overrides: [.cursor: "/nowhere/at/all/cursor-agent"])

        #expect(!found.contains(.cursor))
    }

    @Test("answers in the catalogue's own order")
    func isOrdered() {
        let found = AgentCatalog.installedKinds(overrides: [.codex: "/bin/ls", .openCode: "/bin/ls"])
        let ordered = AgentKind.allCases.filter(found.contains)

        #expect(found == ordered)
    }

    @Test("files an executable path under the key the Agents pane uses")
    func settingKeySpelling() {
        #expect(AgentCatalog.executablePathSettingKey(.claudeCode) == "agent.claudeCode.executablePath")
        #expect(AgentCatalog.executablePathSettingKey(.codex) == "agent.codex.executablePath")
    }
}
