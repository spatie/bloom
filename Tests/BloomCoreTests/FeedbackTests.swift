import Foundation
import Testing
@testable import BloomCore

/// Feedback and prompt submissions are the only things Bloom sends that a person composed, so what
/// travels with them is pinned here: the exact keys, the caps, and above all the things that must
/// never be in a body no matter what the machine they were sent from is called.
@Suite("Feedback")
struct FeedbackTests {
    private func environment(
        token: String = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        appVersion: String = "0.4.0",
        appBuild: String = "412",
        macOSVersion: String = "26.1.0",
        architecture: Feedback.Architecture = .appleSilicon,
        buildChannel: Feedback.BuildChannel = .release,
        agent: String = "claude",
        agentVersion: String = "2.1.234",
        agentsInstalled: [String] = ["codex", "claude"],
        permissionMode: String = "accept_edits",
        theme: InstallPing.Theme = .dark,
        displayScale: String = "2",
        language: String = "en"
    ) -> Feedback.Environment {
        Feedback.Environment(
            token: token,
            appVersion: appVersion,
            appBuild: appBuild,
            macOSVersion: macOSVersion,
            architecture: architecture,
            buildChannel: buildChannel,
            agent: agent,
            agentVersion: agentVersion,
            agentsInstalled: agentsInstalled,
            permissionMode: permissionMode,
            theme: theme,
            displayScale: displayScale,
            language: language
        )
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try Feedback.body(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func string(_ value: some Encodable) throws -> String {
        String(decoding: try Feedback.body(value), as: UTF8.self)
    }

    // MARK: - What is in a body

    @Test("a report has exactly four fields")
    func reportKeys() throws {
        let json = try object(
            Feedback.Report(message: "the sidebar flickers", logs: "10:00:00  archive  nope", images: [], environment: environment())
        )

        #expect(Set(json.keys) == ["message", "logs", "images", "environment"])
    }

    @Test("logs are absent rather than empty when the box was not ticked")
    func reportWithoutLogs() throws {
        let json = try object(Feedback.Report(message: "hello", logs: nil, images: [], environment: environment()))

        #expect(Set(json.keys) == ["message", "images", "environment"])
    }

    @Test("a prompt submission has exactly three fields")
    func promptKeys() throws {
        let json = try object(Feedback.PromptSubmission(prompt: "make the sidebar narrower", name: "Freek", environment: environment()))

        #expect(Set(json.keys) == ["prompt", "name", "environment"])
    }

    @Test("an unnamed prompt submission carries no name key at all")
    func promptWithoutName() throws {
        let json = try object(Feedback.PromptSubmission(prompt: "make it narrower", name: "   ", environment: environment()))

        #expect(Set(json.keys) == ["prompt", "environment"])
    }

    @Test("the environment says exactly thirteen things and no fourteenth")
    func environmentKeys() throws {
        let json = try object(environment())

        #expect(Set(json.keys) == [
            "token",
            "app_version",
            "app_build",
            "macos_version",
            "architecture",
            "build_channel",
            "agent",
            "agent_version",
            "agents_installed",
            "permission_mode",
            "theme",
            "display_scale",
            "language",
        ])
    }

    @Test("the environment sends the facts as the endpoint expects them")
    func environmentValues() throws {
        let json = try object(environment())

        #expect(json["token"] as? String == "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        #expect(json["app_version"] as? String == "0.4.0")
        #expect(json["app_build"] as? String == "412")
        #expect(json["macos_version"] as? String == "26.1.0")
        #expect(json["architecture"] as? String == "apple_silicon")
        #expect(json["build_channel"] as? String == "release")
        #expect(json["agent"] as? String == "claude")
        #expect(json["agent_version"] as? String == "2.1.234")
        #expect(json["agents_installed"] as? [String] == ["claude", "codex"])
        #expect(json["permission_mode"] as? String == "accept_edits")
        #expect(json["theme"] as? String == "dark")
        #expect(json["display_scale"] as? String == "2")
        #expect(json["language"] as? String == "en")
    }

    // MARK: - What may never be in one

    /// The test the whole file exists for. A machine whose every fact is a path, a name or a
    /// credential still produces a body with none of them in it.
    @Test("nothing personal survives into a body, whatever it was handed")
    func nothingPersonalSurvives() throws {
        let hostile = environment(
            token: "/Users/someone/.claude.json",
            appVersion: "0.4.0 (built by someone on someones-macbook)",
            appBuild: "sk-ant-api03-abcdefghijklmnop",
            macOSVersion: "someone@example.com",
            agent: "/opt/homebrew/bin/claude",
            agentVersion: "/Users/someone/.bun/bin/claude 2.1.0",
            agentsInstalled: ["~/dev/code/secret-project"],
            permissionMode: "Full Access, granted by someone",
            displayScale: "someones-macbook",
            language: "en_BE"
        )

        let body = try string(
            Feedback.Report(message: "it broke", logs: nil, images: [], environment: hostile)
        )

        #expect(!body.contains("someone"))
        #expect(!body.contains("/Users"))
        #expect(!body.contains("homebrew"))
        #expect(!body.contains("sk-ant"))
        #expect(!body.contains(".claude.json"))
        #expect(!body.contains("secret-project"))
        #expect(!body.contains("@example.com"))
        #expect(!body.contains("macbook"))
        #expect(!body.contains("en_BE"))
    }

    @Test("a token that was not generated by Bloom is replaced rather than sent")
    func tokenIsAlwaysAUUID() {
        let replaced = environment(token: "not a token").token

        #expect(UUID(uuidString: replaced) != nil)
    }

    @Test("a CLI that did not answer says nothing, rather than claiming a version")
    func missingAgentVersion() throws {
        let json = try object(environment(agentVersion: ""))

        #expect(json["agent_version"] as? String == "")
    }

    @Test("a log excerpt travels exactly as the excerpt made it")
    func logsAreCarriedVerbatim() throws {
        let excerpt = AppLogExcerpt.excerpt(
            [AppLogExcerpt.Entry(date: Date(), category: "archive", message: "could not archive /Users/someone/dev/x")],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let json = try object(Feedback.Report(message: "hi", logs: excerpt, images: [], environment: environment()))

        #expect(json["logs"] as? String == excerpt)
        #expect(!excerpt.contains("someone"))
    }

    // MARK: - Caps

    @Test("a very long message is cut rather than refused")
    func messageCap() {
        let report = Feedback.Report(
            message: String(repeating: "a", count: Feedback.maxMessageCharacters + 500),
            logs: nil,
            images: [],
            environment: environment()
        )

        #expect(report.message.count == Feedback.maxMessageCharacters)
    }

    @Test("a fifth image is not sent")
    func imageCountCap() {
        let images = (0..<6).map {
            Feedback.Image(filename: "shot\($0).png", contentType: "image/png", data: Data([0x89]))
        }

        let report = Feedback.Report(message: "hi", logs: nil, images: images, environment: environment())

        #expect(report.images.count == Feedback.maxImages)
    }

    @Test("an image name is a name, never a path")
    func imageNamesAreCleaned() {
        let image = Feedback.Image(
            filename: "/Users/someone/Desktop/Screenshot 2026-08-21 at 10.11.12.png",
            contentType: "image/png",
            data: Data()
        )

        #expect(image.filename == "Screenshot 2026-08-21 at 10.11.12.png")
    }

    @Test("an unfamiliar content type is not repeated back")
    func contentTypeIsChecked() {
        #expect(Feedback.Image(filename: "a.png", contentType: "text/html", data: Data()).contentType == "image/png")
        #expect(Feedback.Image(filename: "a.jpg", contentType: "image/jpeg", data: Data()).contentType == "image/jpeg")
    }

    @Test("a report with no words in it cannot be sent")
    func emptyMessageCannotSend() {
        #expect(!Feedback.canSend(message: "   \n "))
        #expect(Feedback.canSend(message: "it broke"))
    }

    // MARK: - Where it goes

    @Test("both kinds go to runbloom.app unless a local endpoint is named")
    func endpoints() {
        #expect(Feedback.endpoint(.report, environment: [:])?.absoluteString == Feedback.reportEndpoint)
        #expect(Feedback.endpoint(.prompt, environment: [:])?.absoluteString == Feedback.promptEndpoint)
    }

    @Test("a local endpoint wins, which is the only way this is developed")
    func endpointOverride() {
        let found = Feedback.endpoint(
            .report, environment: ["BLOOM_FEEDBACK_URL": "http://127.0.0.1:8787/api/feedback-reports"]
        )

        #expect(found?.absoluteString == "http://127.0.0.1:8787/api/feedback-reports")
    }

    @Test("an override that is not an http URL is refused")
    func endpointOverrideIsChecked() {
        #expect(Feedback.endpoint(.report, environment: ["BLOOM_FEEDBACK_URL": "file:///tmp/out.json"]) == nil)
        #expect(Feedback.endpoint(.report, environment: ["BLOOM_FEEDBACK_URL": "   "])?.absoluteString == Feedback.reportEndpoint)
    }

    @Test("the request says what it is and carries no cookies")
    func requestShape() throws {
        let body = try Feedback.body(Feedback.Report(message: "hi", logs: nil, images: [], environment: environment()))
        let request = Feedback.request(to: URL(string: "https://example.test/x")!, body: body, appVersion: "0.4.0")

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Bloom/0.4.0")
        #expect(request.httpShouldHandleCookies == false)
    }

    // MARK: - What the answer means

    @Test("what each status code means to somebody watching")
    func outcomes() {
        #expect(Feedback.outcome(statusCode: 202) == .sent)
        #expect(Feedback.outcome(statusCode: 422) == .refused)
        #expect(Feedback.outcome(statusCode: 429, retryAfter: "120") == .throttled(retryAfter: 120))
        #expect(Feedback.outcome(statusCode: 503) == .unreachable)
        #expect(Feedback.outcome(statusCode: 0) == .unreachable)
    }

    @Test("every failure says the text is still there, and success says nothing")
    func failureMessages() {
        #expect(Feedback.failureMessage(.sent) == nil)

        for outcome: Feedback.Outcome in [.refused, .throttled(retryAfter: nil), .unreachable] {
            let message = try! #require(Feedback.failureMessage(outcome))
            #expect(!message.isEmpty)
        }

        #expect(Feedback.failureMessage(.unreachable)?.contains(Feedback.supportEmail) == true)
    }

    // MARK: - What the machine is

    @Test("a build knows which kind of build it is")
    func buildChannels() {
        #expect(Feedback.BuildChannel(buildChannel: "release", masterCommit: nil) == .release)
        #expect(Feedback.BuildChannel(buildChannel: "release", masterCommit: "abc1234") == .master)
        #expect(Feedback.BuildChannel(buildChannel: nil, masterCommit: nil) == .local)
    }

    @Test("Rosetta is its own answer, not a lie about the hardware")
    func architectures() {
        #expect(Feedback.Architecture(isARM: true, isTranslated: false) == .appleSilicon)
        #expect(Feedback.Architecture(isARM: false, isTranslated: false) == .intel)
        #expect(Feedback.Architecture(isARM: true, isTranslated: true) == .rosetta)
    }

    @Test("every permission mode has a wire name the endpoint accepts")
    func permissionModeWireNames() {
        for mode in PermissionMode.allCases {
            let name = Feedback.wireName(mode)
            #expect(InstallPing.matches(name, InstallPing.namePattern))
        }
    }

    // MARK: - The copy

    @Test("the logs checkbox says what it sends, and the sheet says how to reach a person")
    func copyDescribesWhatIsSent() {
        #expect(Feedback.Copy.logsDetail.contains("half hour"))
        #expect(Feedback.Copy.logsDetail.contains("View"))
        #expect(Feedback.Copy.reportBlurb.contains(Feedback.supportEmail))
        #expect(Feedback.Copy.environmentNote.contains("No file"))
    }
}
