import Foundation

/// The two things somebody can deliberately send from Bloom: a feedback report, and a prompt for
/// the agent that builds Bloom.
///
/// Both go to the same place the install ping goes, and everything about them that is a judgement
/// rather than a passthrough is here, in the core, where it is under test: what may be in a body,
/// what may never be, how big any of it is allowed to get, and what each answer from the server
/// means. The app target is left with the three things that need a running app: reading this
/// bundle's version, asking the machine what it is, and putting the request on the wire.
///
/// **The difference from `InstallPing`.** The ping is automatic, so it carries the least it can
/// get away with. These are typed by a person who pressed a menu item and then pressed Send, so
/// they carry what they were given: a message, optionally an excerpt of Bloom's own log, and
/// optionally a picture. What they do NOT carry is anything the person did not choose to put in
/// them, which is why the environment block below is a fixed list of facts about the machine and
/// never a dictionary somebody can add a field to by accident.
///
/// **What is deliberately absent, in both bodies.** No path, no repository, no project, no branch,
/// no worktree location, no workspace name, no prompt or diff from anybody's session, no hostname,
/// no username, no email address, no serial number, no hardware identifier, no credential, and
/// nothing read out of `~/.claude.json` or `~/.codex/auth.json`. Those two files hold live tokens
/// and nothing here opens them: "which backend is configured" is answered by whether the CLI
/// resolves on `PATH`. The log excerpt is the one field that could carry any of this by accident,
/// and `AppLogExcerpt` exists to make sure it does not.
///
/// **The token.** The same anonymous install token the ping uses, so two reports from the same
/// copy of Bloom can be recognised as such and a fix can be told to the person who asked for it.
/// It is a random UUID generated on this Mac, derived from nothing, and joinable against nothing
/// but another thing this copy of Bloom sent. See `InstallPing.installToken(in:)`.
public enum Feedback {
    // MARK: - Where it goes

    /// The endpoints, as agreed with the application that serves them.
    ///
    /// **The exact field names below are the contract with that application** and must not drift.
    /// They are stated once, in `CodingKeys`, and pinned by a test that asserts the whole set of
    /// keys rather than the presence of any one of them.
    public static let reportEndpoint = "https://runbloom.app/api/feedback-reports"
    public static let promptEndpoint = "https://runbloom.app/api/prompt-submissions"

    /// Points a build at a different endpoint, for developing against a local server. The same
    /// affordance as `InstallPing.endpointVariable`, and the only way this feature can be worked
    /// on without putting a row in the real table.
    public static let reportEndpointVariable = "BLOOM_FEEDBACK_URL"
    public static let promptEndpointVariable = "BLOOM_PROMPT_URL"

    /// Which of the two a submission is.
    public enum Kind: Sendable, Equatable, CaseIterable {
        case report
        case prompt

        var endpoint: String {
            switch self {
            case .report: Feedback.reportEndpoint
            case .prompt: Feedback.promptEndpoint
            }
        }

        var variable: String {
            switch self {
            case .report: Feedback.reportEndpointVariable
            case .prompt: Feedback.promptEndpointVariable
            }
        }
    }

    /// Where a submission of this kind goes.
    ///
    /// Unlike the ping, every build may send. A person who found a bug in a build they made
    /// themselves has found a bug, and refusing to carry their report because their copy has no
    /// version stamped on it would be refusing the most useful reports there are. The environment
    /// block says which kind of build it came from, so a report from a working copy is readable as
    /// one. See `BuildChannel`.
    public static func endpoint(_ kind: Kind, environment: [String: String]) -> URL? {
        let override = environment[kind.variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return validEndpoint(override) }
        return validEndpoint(kind.endpoint)
    }

    /// http and https only, and a host is required, for the reason `InstallPing` gives: a `file:`
    /// URL in that environment variable would be a way to make the app write a body somewhere on
    /// the disk.
    private static func validEndpoint(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - How big anything may be

    /// The most somebody may write, and the most that will be sent if they write more.
    ///
    /// Generous rather than tight: a good bug report is a paragraph and a bad one is a page, and
    /// neither is worth refusing over. Text past this is cut rather than the send being refused,
    /// because a Send button that goes grey when a report gets long is a report nobody finishes.
    public static let maxMessageCharacters = 5_000
    public static let maxPromptCharacters = 5_000

    /// The name on a prompt submission, which is a credit line rather than an identity.
    public static let maxNameCharacters = 80

    /// How many pictures may go with one report, and how big each one and all of them may be.
    ///
    /// Four is enough for a before, an after, and the two other places it goes wrong. Two
    /// megabytes takes any screenshot on any Mac, and six is the ceiling on the whole request,
    /// because a body larger than that stops being a feedback report and starts being an upload
    /// somebody's phone tether has to pay for.
    public static let maxImages = 4
    public static let maxImageBytes = 2 * 1024 * 1024
    public static let maxTotalImageBytes = 6 * 1024 * 1024

    /// What the endpoint refuses outright. Well clear of the caps above and their base64 overhead,
    /// so a body that is inside every cap here is never a body the server drops.
    public static let maximumBodyBytes = 12 * 1024 * 1024

    /// What is said when a picture is too big, in the same voice `AttachmentFiles` uses for the
    /// same refusal in the composer.
    public static func tooLargeMessage(name: String, bytes: Int) -> String {
        "\(name) is \(size(bytes)), and Bloom sends images up to \(size(maxImageBytes)) each. "
            + "Scale it down, or send a crop of the part that matters."
    }

    public static func tooManyMessage() -> String {
        "Bloom sends up to \(maxImages) images with one report."
    }

    public static func tooMuchMessage() -> String {
        "That is more than \(size(maxTotalImageBytes)) of images, which is as much as Bloom sends "
            + "in one report. Take one off, or send a smaller one."
    }

    public static func notAnImageMessage(name: String) -> String {
        "\(name) is not an image. Feedback carries pictures only."
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - What the machine is

    /// Whether this copy was built as a release, installed from a commit by `master.sh`, or built
    /// on the machine it is running on.
    ///
    /// Worth a field of its own because it changes how a report should be read: a crash in a
    /// release is everybody's crash, and the same crash in somebody's own build of a branch may be
    /// the branch. Read off the same two Info.plist keys `SoftwareUpdate.availability` and
    /// `InstallPing.endpoint(buildChannel:masterCommit:environment:)` read, so the three cannot
    /// disagree about what kind of build this is.
    public enum BuildChannel: String, Sendable, Equatable, CaseIterable, Codable {
        case release
        case master
        case local

        public init(buildChannel: String?, masterCommit: String?) {
            if let masterCommit, !masterCommit.isEmpty {
                self = .master
            } else if buildChannel == InstallPing.releaseChannel {
                self = .release
            } else {
                self = .local
            }
        }
    }

    /// Which processor this is running on.
    ///
    /// The single most useful fact after the version, because "only on Intel" is often the whole
    /// answer, and because Rosetta is its own category: an Apple silicon Mac running a translated
    /// build behaves like neither of the other two.
    public enum Architecture: String, Sendable, Equatable, CaseIterable, Codable {
        case appleSilicon = "apple_silicon"
        case intel
        case rosetta
        case unknown

        /// Decided from the two facts the app can ask the kernel for: what the hardware is, and
        /// whether this process is being translated.
        public init(isARM: Bool, isTranslated: Bool) {
            if isTranslated {
                self = .rosetta
            } else if isARM {
                self = .appleSilicon
            } else {
                self = .intel
            }
        }
    }

    /// The permission mode, as a wire name.
    ///
    /// `PermissionMode`'s own raw values are camelCase, which the endpoint's name pattern does not
    /// accept, so the mapping is stated here rather than left to a `rawValue` that would quietly
    /// start failing validation. Stable, because these are stored and grouped by: renaming one
    /// splits a column on somebody's chart in two.
    public static func wireName(_ mode: PermissionMode) -> String {
        switch mode {
        case .auto: "ask"
        case .acceptEdits: "accept_edits"
        case .bypassPermissions: "full_access"
        case .plan: "plan"
        }
    }

    /// Everything Bloom is allowed to say about where it is running, and nothing else.
    ///
    /// Thirteen stored properties and no dictionary, so there is no shape of this type that
    /// carries a fourteenth fact. Every string is checked against the pattern the endpoint
    /// validates it with, using the same checks and the same patterns the install ping uses, so
    /// the two can never disagree about what a version string looks like. Anything that does not
    /// match is replaced by a value that does and that obviously means "we could not tell".
    ///
    /// Adding a field here is the only way to change what leaves the machine with a report, which
    /// is the property this whole design is arranged around.
    public struct Environment: Sendable, Equatable, Encodable {
        /// The anonymous install token. See `InstallPing.installToken(in:)`.
        public let token: String
        /// `CFBundleShortVersionString`, e.g. `0.4.0`.
        public let appVersion: String
        /// `CFBundleVersion`, which is the build number inside that version.
        public let appBuild: String
        /// `26.1.0`.
        public let macOSVersion: String
        public let architecture: Architecture
        public let buildChannel: BuildChannel
        /// Which coding agent Bloom runs here, as `InstallPing.agentName(installed:)` answers it.
        public let agent: String
        /// The version that agent's CLI reports, e.g. `2.1.234`. Empty when the CLI is not
        /// installed or did not answer.
        public let agentVersion: String
        /// Every backend whose CLI resolves on this machine, sorted, as wire names. The fact that
        /// a binary exists, and nothing about the account it is signed in with.
        public let agentsInstalled: [String]
        /// The permission mode new sessions start in. See `wireName(_:)`.
        public let permissionMode: String
        /// The appearance setting.
        public let theme: InstallPing.Theme
        /// `2.0` on every Mac made this decade, `1.0` on an external display that is not Retina.
        public let displayScale: String
        /// The language Bloom is being read in, as a bare code: `en`, `nl`. Not the region, not
        /// the locale, and not the keyboard layout.
        public let language: String

        public init(
            token: String,
            appVersion: String,
            appBuild: String,
            macOSVersion: String,
            architecture: Architecture,
            buildChannel: BuildChannel,
            agent: String,
            agentVersion: String = "",
            agentsInstalled: [String] = [],
            permissionMode: String,
            theme: InstallPing.Theme,
            displayScale: String,
            language: String
        ) {
            self.token = InstallPing.matches(token, InstallPing.tokenPattern) ? token : InstallPing.newToken()
            self.appVersion = InstallPing.checked(
                appVersion, InstallPing.appVersionPattern, or: InstallPing.unknownVersion
            )
            self.appBuild = InstallPing.checked(
                appBuild, InstallPing.appVersionPattern, or: InstallPing.unknownVersion
            )
            self.macOSVersion = InstallPing.checked(
                macOSVersion, InstallPing.systemVersionPattern, or: InstallPing.unknownVersion
            )
            self.architecture = architecture
            self.buildChannel = buildChannel
            self.agent = InstallPing.checked(agent, InstallPing.namePattern, or: InstallPing.unknownName)
            // Empty rather than `0.0.0` when there is nothing to say: a CLI that did not answer is
            // not the same as one reporting a version nobody released.
            self.agentVersion = agentVersion.isEmpty
                ? ""
                : InstallPing.checked(agentVersion, Feedback.agentVersionPattern, or: "")
            self.agentsInstalled = agentsInstalled
                .map { InstallPing.checked($0, InstallPing.namePattern, or: InstallPing.unknownName) }
                .sorted()
            self.permissionMode = InstallPing.checked(
                permissionMode, InstallPing.namePattern, or: InstallPing.unknownName
            )
            self.theme = theme
            self.displayScale = InstallPing.checked(
                displayScale, Feedback.scalePattern, or: InstallPing.unknownVersion
            )
            self.language = InstallPing.checked(language, Feedback.languagePattern, or: InstallPing.unknownName)
        }

        /// snake_case, because the application receiving this is a Laravel app and this is the
        /// shape it validates. These names are the contract with it and must not drift.
        enum CodingKeys: String, CodingKey {
            case token
            case appVersion = "app_version"
            case appBuild = "app_build"
            case macOSVersion = "macos_version"
            case architecture
            case buildChannel = "build_channel"
            case agent
            case agentVersion = "agent_version"
            case agentsInstalled = "agents_installed"
            case permissionMode = "permission_mode"
            case theme
            case displayScale = "display_scale"
            case language
        }
    }

    /// A CLI version is whatever the CLI chose to print, so this is looser than the app's own
    /// pattern and still refuses anything that is not a version: no spaces, no paths, no prose.
    public static let agentVersionPattern = #"^[0-9][A-Za-z0-9.+-]{0,31}$"#

    /// `1`, `2`, `1.5`, and nothing else.
    public static let scalePattern = #"^\d(\.\d{1,2})?$"#

    /// A bare language code. Not a locale: `en_BE` says where somebody is.
    public static let languagePattern = #"^[a-z]{2,8}$"#

    // MARK: - What is sent

    /// One picture attached to a report.
    ///
    /// The bytes travel inside the JSON as base64, which is what `JSONEncoder` does with `Data` on
    /// its own. Nothing about the file it came from travels with it except a name, and the name is
    /// cleaned first: a picture is attached to say what the screen looked like, not to say where
    /// on this Mac it was saved.
    public struct Image: Sendable, Equatable, Encodable {
        public let filename: String
        public let contentType: String
        public let data: Data

        public init(filename: String, contentType: String, data: Data) {
            self.filename = Feedback.safeFilename(filename)
            self.contentType = Feedback.checkedContentType(contentType)
            self.data = data
        }

        enum CodingKeys: String, CodingKey {
            case filename
            case contentType = "content_type"
            case data
        }
    }

    /// The image content types Bloom will send, and the only ones.
    public static let imageContentTypes = ["image/png", "image/jpeg", "image/gif", "image/heic"]

    static func checkedContentType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return imageContentTypes.contains(trimmed) ? trimmed : "image/png"
    }

    /// The last component of a name, with anything that could change what it means taken out.
    ///
    /// A path never travels with a picture, so a name that is a path is reduced to its last
    /// component before anything else happens: `/Users/someone/Desktop/bug.png` is sent as
    /// `bug.png`, and a name that is nothing but slashes and dots becomes `image`.
    public static func safeFilename(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return "image" }
        return String(name.prefix(120))
    }

    /// A feedback report: what somebody wrote, what they chose to attach, and where they are
    /// running.
    public struct Report: Sendable, Equatable, Encodable {
        public let message: String
        /// The log excerpt, or nil when the box was left unticked, which is how it starts. Nil
        /// means the key is absent from the body rather than present and empty.
        public let logs: String?
        public let images: [Image]
        public let environment: Environment

        public init(message: String, logs: String?, images: [Image], environment: Environment) {
            self.message = Feedback.trimmed(message, to: Feedback.maxMessageCharacters)
            self.logs = logs.map { Feedback.trimmed($0, to: AppLogExcerpt.maxCharacters) }
            self.images = Array(images.prefix(Feedback.maxImages))
            self.environment = environment
        }

        enum CodingKeys: String, CodingKey {
            case message
            case logs
            case images
            case environment
        }
    }

    /// A prompt somebody wants run against Bloom itself, and the name to credit it to.
    public struct PromptSubmission: Sendable, Equatable, Encodable {
        public let prompt: String
        /// Nil when nobody typed one, which is allowed: a prompt is worth having anonymously.
        public let name: String?
        public let environment: Environment

        public init(prompt: String, name: String?, environment: Environment) {
            self.prompt = Feedback.trimmed(prompt, to: Feedback.maxPromptCharacters)
            let cleaned = name.map { Feedback.trimmed($0, to: Feedback.maxNameCharacters) } ?? ""
            self.name = cleaned.isEmpty ? nil : cleaned
            self.environment = environment
        }

        enum CodingKeys: String, CodingKey {
            case prompt
            case name
            case environment
        }
    }

    static func trimmed(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
    }

    /// Whether there is anything worth sending. The Send button is keyed on this: a report with no
    /// words in it says nothing that its attachments could not say better with one line.
    public static func canSend(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The request

    /// The JSON body. Sorted keys so the same facts always produce the same bytes, which is what
    /// makes a body assertable in a test.
    public static func body(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// The whole request, built here so the headers are pinned by the same tests as the body.
    ///
    /// A longer timeout than the ping's, because this one can carry six megabytes of screenshots
    /// over whatever connection somebody happens to be on, and unlike the ping it is not going to
    /// be tried again in an hour by itself: a person is watching it, and a failure costs them the
    /// press of a button.
    public static func request(to endpoint: URL, body: Data, appVersion: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Stated rather than left to the system, whose default carries the CFNetwork and Darwin
        // build numbers along with it.
        request.setValue("Bloom/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    // MARK: - What the answer means

    /// What happened, in the words the sheet says it in.
    ///
    /// Every one of these leaves what was typed exactly where it was. That is the rule the whole
    /// sending path is built around: a send that did not work must cost a press of a button and
    /// never a paragraph somebody wrote.
    public enum Outcome: Sendable, Equatable {
        case sent
        /// The server took the request and refused it: a field did not validate, or the body was
        /// too big. Trying the same thing again will fail the same way, so the message says so.
        case refused
        /// A 429. There is a human behind this one, so it says how long rather than going quiet.
        case throttled(retryAfter: TimeInterval?)
        /// No answer, or a 5xx. The site may simply be down.
        case unreachable
    }

    public static func outcome(statusCode: Int, retryAfter: String? = nil, now: Date = Date()) -> Outcome {
        switch statusCode {
        case 200..<300: .sent
        case 429: .throttled(retryAfter: InstallPing.retryAfterSeconds(retryAfter, now: now))
        case 400..<500: .refused
        default: .unreachable
        }
    }

    /// What the sheet says when a send did not work. Plain, specific about whose fault it is, and
    /// it always ends by saying the text is still there.
    public static func failureMessage(_ outcome: Outcome) -> String? {
        switch outcome {
        case .sent:
            nil
        case .refused:
            "The server would not take that report. Nothing has been lost, and mailing "
                + "\(supportEmail) will reach the same person."
        case .throttled(let retryAfter):
            "That is a lot of reports at once. Try again \(waitPhrase(retryAfter)). Your text is still here."
        case .unreachable:
            "Bloom could not reach the server. Your text is still here, so you can try again in a "
                + "moment, or mail \(supportEmail)."
        }
    }

    static func waitPhrase(_ retryAfter: TimeInterval?) -> String {
        guard let retryAfter, retryAfter > 0 else { return "in a minute" }
        let minutes = Int((retryAfter / 60).rounded(.up))
        return minutes <= 1 ? "in a minute" : "in \(minutes) minutes"
    }

    // MARK: - What the sheets say

    /// Where somebody can reach a person instead, which is offered on the sheet rather than
    /// hidden: a form that is the only way to say something is a form that swallows things.
    public static let supportEmail = "support@spatie.be"

    public enum Copy {
        public static let reportTitle = "Feedback"
        public static let reportBlurb =
            "Tell us what is not working, or what you wish Bloom did. You can also mail "
                + "\(Feedback.supportEmail) if you would rather write to a person."
        public static let reportPlaceholder =
            "Tell us about your experience, bugs you have found, or features you would like to see…"
        public static let reportSend = "Send feedback"
        public static let reportSent = "Thank you. That has been sent."

        public static let logsToggle = "Include recent app logs (may include personal data)"
        /// The sentence under the checkbox, which says what "recent" means. A checkbox about
        /// sending data that cannot say how much data is a checkbox nobody can answer.
        public static let logsDetail =
            "The last half hour of what Bloom wrote to its own log. Paths, addresses and anything "
                + "that looks like a credential are taken out, and so are your project, workspace "
                + "and branch names. View shows exactly what would be sent."
        public static let logsView = "View"
        public static let logsTitle = "What would be sent"

        public static let attachImages = "Attach images"

        public static let promptTitle = "Submit a prompt"
        public static let promptBlurb =
            "Prompt a coding agent to build what you want to see in Bloom. If we like your prompt, "
                + "we will run it and merge the result."
        public static let promptPlaceholder = "Describe what you would like to see built…"
        public static let promptName = "Your name (if we use your prompt, we will credit you in the changelog)"
        public static let promptSend = "Submit prompt"
        public static let promptSent = "Thank you. Your prompt is in."

        /// The line under both Send buttons. Short, and it names the two things somebody would
        /// want to know before pressing it.
        public static let environmentNote =
            "Bloom attaches its version, your macOS version and how it is set up here. No file "
                + "paths, project names or account details."
    }
}
