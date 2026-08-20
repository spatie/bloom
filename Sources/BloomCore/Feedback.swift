import Foundation

/// The two things somebody can deliberately send from Bloom: a feedback submission, and a prompt
/// for the agent that builds Bloom.
///
/// Both go to the application that already receives the install ping, and everything about them
/// that is a judgement rather than a passthrough is here, in the core, where it is under test:
/// what may be in a body, what may never be, how big any of it is allowed to get, and what each
/// answer from the server means. The app target is left with the three things that need a running
/// app: reading this bundle's version, asking the machine what it is, and putting the request on
/// the wire.
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
/// **The endpoint's own shapes are narrow on purpose**, and they are restated here and checked
/// against before anything is sent. None of the environment fields admits a slash, a space or an
/// `@`, which is what makes it impossible for a path, a hostname or an address to fit in one of
/// them even by accident. A field that does not match is dropped rather than coerced into
/// something plausible.
///
/// **The install token.** The same anonymous token the ping uses, sent so that a submission can be
/// read beside the install it came from. Optional to the endpoint, which falls back to a hashed
/// address for its throttle when it is missing. It is a random UUID generated on this Mac, derived
/// from nothing, and joinable against nothing but another thing this copy of Bloom sent. See
/// `InstallPing.installToken(in:)`.
public enum Feedback {
    // MARK: - Where it goes

    /// The endpoints, as agreed with the application that serves them.
    public static let reportEndpoint = "https://runbloom.app/api/feedback-submissions"
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
    /// one. See `InstallSource`.
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

    /// What the endpoint accepts, restated. Text past this is cut here rather than the send being
    /// refused there: a 422 for length is a report somebody wrote and lost.
    public static let maxMessageCharacters = 5_000
    public static let maxPromptCharacters = 5_000

    /// The endpoint's own ceiling on the log field. Bloom's excerpt is capped at a third of it by
    /// `AppLogExcerpt`, which is the cap that actually bites.
    public static let maxLogCharacters = 60_000

    /// The name on a prompt submission, which is a credit line rather than an identity.
    public static let maxNameCharacters = 60

    /// How many pictures may go with one submission, and how big each may be. The endpoint's
    /// numbers.
    public static let maxImages = 5
    public static let maxImageBytes = 4 * 1024 * 1024

    /// How much picture Bloom will put in one request.
    ///
    /// Below five times the per-image cap on purpose. Twenty megabytes of screenshots is not a bug
    /// report, it is an upload, and the honest place to refuse it is here, with a sentence, rather
    /// than at the far end with a 413.
    public static let maxTotalImageBytes = 12 * 1024 * 1024

    /// What a request may weigh in total, after multipart framing.
    public static let maximumBodyBytes = 16 * 1024 * 1024

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
        "\(name) is not an image Bloom can send. PNG, JPEG, GIF, WebP and HEIC go; PDFs and SVGs "
            + "do not."
    }

    /// How much room is left, said only when it is nearly gone. See `FeedbackSheet`.
    public static func remainingMessage(count: Int, limit: Int) -> String? {
        guard count > limit - 500 else { return nil }
        guard count <= limit else {
            return "\(count) characters. Only the first \(limit) will be sent."
        }
        return "\(limit - count) characters left"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - What the machine is

    /// Whether this copy is a release somebody installed or a build somebody made.
    ///
    /// Two values, because that is what the endpoint stores, and the line falls exactly where it
    /// matters: a crash in a release is everybody's crash, and the same crash in a working copy of
    /// the source tree may be the working copy. A build `master.sh` installed is a build of a
    /// commit somebody made on their own machine, so it is `local` too.
    ///
    /// Read off the same two Info.plist keys `SoftwareUpdate.availability` and
    /// `InstallPing.endpoint(buildChannel:masterCommit:environment:)` read, so the three cannot
    /// disagree about what kind of build this is.
    public enum InstallSource: String, Sendable, Equatable, CaseIterable, Codable {
        case release
        case local

        public init(buildChannel: String?, masterCommit: String?) {
            let isMasterBuild = !(masterCommit ?? "").isEmpty
            self = (!isMasterBuild && buildChannel == InstallPing.releaseChannel) ? .release : .local
        }
    }

    /// Which slice this process is actually running as.
    ///
    /// The endpoint takes `arm64` or `x86_64`, which are the two things a process can be, so
    /// Rosetta is reported as what it is from the inside: an `x86_64` process. That is the answer
    /// a bug report needs, because a translated Bloom behaves like an Intel Bloom. The hardware
    /// underneath it is not sent, and `unknown` sends nothing at all rather than guessing.
    public enum Architecture: Sendable, Equatable, CaseIterable {
        case arm64
        case x86_64
        case unknown

        /// Decided from the two facts the app can ask the kernel for: what the hardware is, and
        /// whether this process is being translated.
        public init(isARM: Bool, isTranslated: Bool) {
            if isTranslated {
                self = .x86_64
            } else if isARM {
                self = .arm64
            } else {
                self = .x86_64
            }
        }

        /// Nil when there is nothing worth saying, which drops the field from the body.
        public var wireName: String? {
            switch self {
            case .arm64: "arm64"
            case .x86_64: "x86_64"
            case .unknown: nil
            }
        }
    }

    /// The permission mode, as the slug the endpoint stores.
    ///
    /// `PermissionMode`'s own raw values are camelCase, which the endpoint's slug pattern does not
    /// accept, so the mapping is stated here rather than left to a `rawValue` that would quietly
    /// start failing validation. Stable, because these are stored and grouped by: renaming one
    /// splits a column on somebody's chart in two.
    public static func wireName(_ mode: PermissionMode) -> String {
        switch mode {
        case .auto: "ask"
        case .acceptEdits: "accept-edits"
        case .bypassPermissions: "full-access"
        case .plan: "plan"
        }
    }

    // MARK: - The environment block

    /// One field of the environment block, as it goes out.
    ///
    /// A small closed set of shapes rather than `Any`, because both bodies are built from the same
    /// list: JSON writes a string, a number or an array, and multipart writes `environment[name]`
    /// or a repeated `environment[name][]`. Two representations of one list, and no way for them
    /// to disagree about what is in it.
    public enum FieldValue: Sendable, Equatable {
        case text(String)
        case number(Double)
        case list([String])
    }

    public struct Field: Sendable, Equatable {
        public let name: String
        public let value: FieldValue

        public init(name: String, value: FieldValue) {
            self.name = name
            self.value = value
        }
    }

    /// Everything Bloom is allowed to say about where it is running, and nothing else.
    ///
    /// Twelve stored properties and no dictionary, so there is no shape of this type that carries
    /// a thirteenth fact. Every string is checked against the pattern the endpoint validates it
    /// with, by the same two functions the install ping is checked with, so the two can never
    /// disagree about what a version string looks like. A field that does not match is left out of
    /// the body: the endpoint takes an environment block with any subset of its keys, so a fact
    /// Bloom could not establish is better missing than guessed.
    ///
    /// Adding a field here is the only way to change what leaves the machine with a submission,
    /// which is the property this whole design is arranged around.
    public struct Environment: Sendable, Equatable, Encodable {
        /// `CFBundleShortVersionString`, e.g. `0.4.0`.
        public let appVersion: String
        /// `CFBundleVersion`, the build number inside that version.
        public let appBuild: String
        /// `26.1.0`.
        public let macOSVersion: String
        public let architecture: Architecture
        public let installSource: InstallSource
        /// Which coding agent Bloom runs here, as `InstallPing.agentName(installed:)` answers it.
        public let agent: String
        /// What that agent's CLI reports, e.g. `2.1.234`. Empty when it is not installed or did
        /// not answer, and then the field is left out.
        public let agentVersion: String
        /// Every backend whose CLI resolves on this machine, sorted, as slugs. The fact that a
        /// binary exists, and nothing about the account it is signed in with.
        public let availableAgents: [String]
        /// The permission mode new sessions start in. See `wireName(_:)`.
        public let permissionMode: String
        /// The appearance setting.
        public let theme: InstallPing.Theme
        /// `2` on every Retina display. A number, between 1 and 4.
        public let displayScale: Double
        /// The language and region Bloom is being read in, as a language tag: `nl-BE`. Built from
        /// two codes rather than from a locale identifier, so nothing a user typed can reach it.
        public let locale: String

        public init(
            appVersion: String,
            appBuild: String,
            macOSVersion: String,
            architecture: Architecture,
            installSource: InstallSource,
            agent: String,
            agentVersion: String = "",
            availableAgents: [String] = [],
            permissionMode: String,
            theme: InstallPing.Theme,
            displayScale: Double,
            locale: String
        ) {
            self.appVersion = InstallPing.checked(appVersion, InstallPing.appVersionPattern, or: "")
            self.appBuild = InstallPing.checked(appBuild, InstallPing.appVersionPattern, or: "")
            self.macOSVersion = InstallPing.checked(macOSVersion, InstallPing.systemVersionPattern, or: "")
            self.architecture = architecture
            self.installSource = installSource
            self.agent = InstallPing.checked(agent, Feedback.slugPattern, or: "")
            self.agentVersion = InstallPing.checked(agentVersion, Feedback.agentVersionPattern, or: "")
            self.availableAgents = Array(
                availableAgents
                    .map { InstallPing.checked($0, Feedback.slugPattern, or: "") }
                    .filter { !$0.isEmpty }
                    .sorted()
                    .prefix(Feedback.maxAgentSlugs)
            )
            self.permissionMode = InstallPing.checked(permissionMode, Feedback.slugPattern, or: "")
            self.theme = theme
            // Clamped rather than dropped: a scale outside this range is a screen nobody has, and
            // the nearest end of the range is a truer answer than silence.
            self.displayScale = min(max(displayScale, 1), 4)
            self.locale = InstallPing.checked(locale, Feedback.localePattern, or: "")
        }

        /// The block as it goes out, in a fixed order, with everything Bloom could not establish
        /// left out.
        ///
        /// **This is the only description of the block.** The JSON encoding below and the
        /// multipart writer both read it, so a field cannot exist in one body and be missing from
        /// the other, and a test that counts these counts what actually leaves the machine.
        public var fields: [Field] {
            var found: [Field] = []

            func text(_ name: String, _ value: String) {
                guard !value.isEmpty else { return }
                found.append(Field(name: name, value: .text(value)))
            }

            text("app_version", appVersion)
            text("app_build", appBuild)
            text("macos_version", macOSVersion)
            text("architecture", architecture.wireName ?? "")
            text("install_source", installSource.rawValue)
            text("agent", agent)
            text("agent_version", agentVersion)
            if !availableAgents.isEmpty {
                found.append(Field(name: "available_agents", value: .list(availableAgents)))
            }
            text("permission_mode", permissionMode)
            text("theme", theme.rawValue)
            found.append(Field(name: "display_scale", value: .number(displayScale)))
            text("locale", locale)

            return found
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            for field in fields {
                let key = WireKey(field.name)
                switch field.value {
                case .text(let value): try container.encode(value, forKey: key)
                case .number(let value): try container.encode(value, forKey: key)
                case .list(let value): try container.encode(value, forKey: key)
                }
            }
        }
    }

    /// The most agent slugs the endpoint will read.
    public static let maxAgentSlugs = 12

    /// A key whose name is decided at runtime, so the environment block can be written from
    /// `fields` rather than from a second list of coding keys that would drift from it.
    struct WireKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: - The endpoint's own rules, restated

    /// A slug: lowercase, and no slash, space or `@`, which is what makes it impossible for a
    /// path, a host or an address to be sent as one.
    public static let slugPattern = #"^[a-z][a-z0-9_-]{0,31}$"#

    /// A CLI version is whatever the CLI chose to print, so this is looser than the app's own
    /// pattern and still refuses anything that is not a version: no spaces, no paths, no prose.
    public static let agentVersionPattern = #"^[0-9][A-Za-z0-9.+-]{0,31}$"#

    /// `nl-BE`, `en`. A language tag built from codes, never a locale identifier.
    public static let localePattern = #"^[a-z]{2,8}(-[A-Za-z0-9]{2,8})?$"#

    /// What a name on a prompt submission may be, as the endpoint validates it: letters, numbers,
    /// spaces and a few marks. No `@`, which means an email address is refused, which is why the
    /// field says so before anybody types one.
    public static let namePattern = #"^[\p{L}\p{N} ._'-]+$"#

    /// The name as it is sent: trimmed, capped, and with a leading `@` taken off, because a handle
    /// written the way people write handles is the commonest thing anybody will type here and the
    /// endpoint strips it too.
    public static func normalisedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        return String(name.prefix(maxNameCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a name would be accepted. Empty is fine: the field is optional, and a prompt is
    /// worth having anonymously.
    public static func isAcceptableName(_ raw: String) -> Bool {
        let name = normalisedName(raw)
        return name.isEmpty || InstallPing.matches(name, namePattern)
    }

    /// What the sheet says under a name it cannot send.
    public static let nameProblem =
        "A name or a handle, please: letters, numbers, spaces, and . _ ' -. An email address will "
            + "not be accepted."

    // MARK: - What is sent

    /// One picture attached to a submission.
    ///
    /// The filename travels as part of the multipart framing because that is how a file part is
    /// written, and the endpoint deliberately does not store it: a filename is free text and free
    /// text is where a path leaks. It is cleaned here anyway, on the way out, so nothing is sent
    /// that was not meant to be sent even for the moment it takes to be dropped.
    public struct Image: Sendable, Equatable {
        public let filename: String
        public let contentType: String
        public let data: Data

        public init(filename: String, contentType: String, data: Data) {
            self.filename = Feedback.safeFilename(filename)
            self.contentType = Feedback.checkedContentType(contentType)
            self.data = data
        }
    }

    /// The image content types the endpoint accepts, sniffed and by extension both.
    public static let imageContentTypes = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif",
    ]

    static func checkedContentType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return imageContentTypes.contains(trimmed) ? trimmed : "image/png"
    }

    /// The last component of a name, with anything that could change what it means taken out.
    ///
    /// A path never travels with a picture, so a name that is a path is reduced to its last
    /// component before anything else happens: `/Users/someone/Desktop/bug.png` is written as
    /// `bug.png`, and a name that is nothing but slashes and dots becomes `image`.
    public static func safeFilename(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "\"", with: "-")
        name = name.replacingOccurrences(of: "\\", with: "-")
        name = name.replacingOccurrences(of: "\r", with: " ")
        name = name.replacingOccurrences(of: "\n", with: " ")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return "image" }
        return String(name.prefix(120))
    }

    /// A feedback submission: what somebody wrote, what they chose to attach, which install it is
    /// from, and where it is running.
    public struct Report: Sendable, Equatable, Encodable {
        public let message: String
        /// The log excerpt, or nil when the box was left unticked, which is how it starts. Nil
        /// means the key is absent from the body rather than present and empty.
        public let logs: String?
        public let images: [Image]
        public let token: String?
        public let environment: Environment

        public init(
            message: String,
            logs: String?,
            images: [Image],
            token: String?,
            environment: Environment
        ) {
            self.message = Feedback.trimmed(message, to: Feedback.maxMessageCharacters)
            self.logs = logs.map { Feedback.trimmed($0, to: Feedback.maxLogCharacters) }
            self.images = Array(images.prefix(Feedback.maxImages))
            self.token = token.flatMap { InstallPing.matches($0, InstallPing.tokenPattern) ? $0 : nil }
            self.environment = environment
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            try container.encode(message, forKey: WireKey("message"))
            try container.encodeIfPresent(logs, forKey: WireKey("logs"))
            try container.encodeIfPresent(token, forKey: WireKey("token"))
            try container.encode(environment, forKey: WireKey("environment"))
        }
    }

    /// A prompt somebody wants run against Bloom itself, and the name to credit it to.
    public struct PromptSubmission: Sendable, Equatable, Encodable {
        public let prompt: String
        /// Nil when nobody typed one, which is allowed: a prompt is worth having anonymously.
        public let name: String?
        public let token: String?
        public let environment: Environment

        public init(prompt: String, name: String?, token: String?, environment: Environment) {
            self.prompt = Feedback.trimmed(prompt, to: Feedback.maxPromptCharacters)
            let cleaned = name.map(Feedback.normalisedName) ?? ""
            // A name the endpoint would refuse is left out rather than sent to be rejected: the
            // sheet has already said what is wrong with it, and losing the credit line is better
            // than losing the prompt.
            self.name = cleaned.isEmpty || !InstallPing.matches(cleaned, Feedback.namePattern) ? nil : cleaned
            self.token = token.flatMap { InstallPing.matches($0, InstallPing.tokenPattern) ? $0 : nil }
            self.environment = environment
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            try container.encode(prompt, forKey: WireKey("prompt"))
            try container.encodeIfPresent(name, forKey: WireKey("name"))
            try container.encodeIfPresent(token, forKey: WireKey("token"))
            try container.encode(environment, forKey: WireKey("environment"))
        }
    }

    static func trimmed(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
    }

    /// Whether there is anything worth sending. The Send button is keyed on this: a submission with
    /// no words in it says nothing that its attachments could not say better with one line.
    public static func canSend(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The request

    /// Bytes, and what they are.
    public struct Body: Sendable, Equatable {
        public let contentType: String
        public let data: Data

        public init(contentType: String, data: Data) {
            self.contentType = contentType
            self.data = data
        }
    }

    /// A submission's body: JSON on its own, multipart when there are pictures.
    ///
    /// Two encodings rather than base64 inside the JSON, because that is what the endpoint reads:
    /// it validates the attachments as uploaded files, sniffing their type rather than trusting
    /// what they are called.
    public static func body(for report: Report, boundary: String = newBoundary()) throws -> Body {
        guard !report.images.isEmpty else {
            return Body(contentType: "application/json", data: try json(report))
        }

        var parts: [MultipartPart] = [.text(name: "message", value: report.message)]
        if let logs = report.logs { parts.append(.text(name: "logs", value: logs)) }
        if let token = report.token { parts.append(.text(name: "token", value: token)) }
        parts += environmentParts(report.environment)
        parts += report.images.map {
            .file(name: "attachments[]", filename: $0.filename, contentType: $0.contentType, data: $0.data)
        }

        return Body(
            contentType: "multipart/form-data; boundary=\(boundary)",
            data: multipart(parts, boundary: boundary)
        )
    }

    public static func body(for submission: PromptSubmission) throws -> Body {
        Body(contentType: "application/json", data: try json(submission))
    }

    /// Sorted keys so the same facts always produce the same bytes, which is what makes a body
    /// assertable in a test.
    static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// The environment block as form fields, nested the way the endpoint reads them.
    static func environmentParts(_ environment: Environment) -> [MultipartPart] {
        environment.fields.flatMap { field -> [MultipartPart] in
            switch field.value {
            case .text(let value):
                [.text(name: "environment[\(field.name)]", value: value)]
            case .number(let value):
                [.text(name: "environment[\(field.name)]", value: number(value))]
            case .list(let values):
                values.map { .text(name: "environment[\(field.name)][]", value: $0) }
            }
        }
    }

    /// `2` rather than `2.0`, so a whole number reads as one on the other side.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    public enum MultipartPart: Sendable, Equatable {
        case text(name: String, value: String)
        case file(name: String, filename: String, contentType: String, data: Data)
    }

    /// A boundary nothing in a body could contain: fixed text and a UUID.
    public static func newBoundary() -> String {
        "BloomFormBoundary\(UUID().uuidString)"
    }

    static func multipart(_ parts: [MultipartPart], boundary: String) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        for part in parts {
            append("--\(boundary)\r\n")
            switch part {
            case .text(let name, let value):
                append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                append(value)
                append("\r\n")
            case .file(let name, let filename, let contentType, let data):
                append(
                    "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                )
                append("Content-Type: \(contentType)\r\n\r\n")
                body.append(data)
                append("\r\n")
            }
        }
        append("--\(boundary)--\r\n")

        return body
    }

    /// The whole request, built here so the headers are pinned by the same tests as the body.
    ///
    /// A longer timeout than the ping's, because this one can carry twelve megabytes of
    /// screenshots over whatever connection somebody happens to be on, and unlike the ping it is
    /// not going to be tried again in an hour by itself: a person is watching it, and a failure
    /// costs them the press of a button.
    public static func request(to endpoint: URL, body: Body, appVersion: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body.data
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Stated rather than left to the system, whose default carries the CFNetwork and Darwin
        // build numbers along with it.
        request.setValue(
            "Bloom/\(appVersion.isEmpty ? InstallPing.unknownVersion : appVersion)",
            forHTTPHeaderField: "User-Agent"
        )
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
            "The server would not take that. Nothing has been lost, and mailing \(supportEmail) "
                + "will reach the same person."
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
            "The last half hour of what Bloom wrote to its own log, and nothing else. Paths, "
                + "addresses and anything that looks like a credential are taken out, and so are "
                + "your project, workspace and branch names. This is the text itself, not a "
                + "sample of it."
        public static let logsView = "View"
        public static let logsTitle = "What would be sent"

        public static let attachImages = "Attach images"

        public static let promptTitle = "Submit a prompt"
        public static let promptBlurb =
            "Prompt a coding agent to build what you want to see in Bloom. If we like your prompt, "
                + "we will run it and merge the result."
        public static let promptPlaceholder = "Describe what you would like to see built…"
        public static let promptName = "Your name (if we use your prompt, we will credit you in the changelog)"
        public static let promptNamePlaceholder = "A name or a handle, not an email address"
        public static let promptSend = "Submit prompt"
        public static let promptSent = "Thank you. Your prompt is in."

        /// The line under both Send buttons. Short, and it names the two things somebody would
        /// want to know before pressing it.
        public static let environmentNote =
            "Bloom attaches its version, your macOS version and how it is set up here. No file "
                + "paths, project names or account details."
    }
}
