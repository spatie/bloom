import Foundation

/// A turn that is still alive and waiting on somebody else's outage.
///
/// The CLI announces every one of these and Bloom used to drop the lot. During an evening of 529s
/// the transcript said "Requesting" with a live dot for three minutes and fourteen seconds while
/// ten `api_retry` lines went past saying exactly what was wrong, and the owner reasonably read
/// three minutes of an unchanging word as a hang. Nothing was hung. The whole point of this file
/// is that the difference between waiting and hung is information Bloom already had.
///
/// Measured, from `claude` 2.1.241 during the outage:
///
/// ```json
/// {"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,
///  "retry_delay_ms":600,"error_status":529,"error":"overloaded"}
/// ```
///
/// and one level down, riding on a `tool_progress` line for an Agent call:
///
/// ```json
/// {"type":"tool_progress","tool_name":"Agent","subagent_type":"general-purpose",
///  "subagent_retry":{"agent_id":"ae8b434e1a270eeac","attempt":1,"max_retries":10,
///                    "retry_delay_ms":576,"error_status":529,"error_category":"overloaded"}}
/// ```
///
/// The two carry the same six facts under two spellings, so they decode to one type with a scope
/// on it rather than to two types that would each need their own wording.
///
/// **Not a stored transcript row.** Ten attempts would be ten rows, and nine of them are stale the
/// moment the tenth arrives. A retry is a live signal like `status`, and what survives the turn is
/// one sentence about the run as a whole. See `RetryRun`.
public struct AgentRetry: Sendable, Hashable {
    /// Which request is being retried: the turn itself, or one subagent inside it.
    public enum Scope: Sendable, Hashable {
        case turn
        /// `agentID` is the CLI's own task id, which is also the id a task notification reports a
        /// failure under, so a row drawn per subagent can find its own retries by it.
        case subagent(agentID: String, toolUseID: String?, kind: String?)

        public var agentID: String? {
            if case .subagent(let id, _, _) = self { return id }
            return nil
        }
    }

    public let scope: Scope
    /// Which attempt has just failed, counting from one.
    public let attempt: Int
    /// How many the CLI will make before it gives up. Ten, in every line measured.
    public let maxAttempts: Int
    /// How long until the next attempt.
    public let delay: TimeInterval
    /// The HTTP status behind it, when the request got far enough to have one.
    public let status: Int?
    /// The CLI's own one-word category (`overloaded`). Read only when there is no status, for the
    /// reason set out on `RetryTrouble.diagnose`.
    public let category: String?
    public let raw: Data
    public let uuid: String?
    public let sessionID: String?

    public init(
        scope: Scope = .turn,
        attempt: Int,
        maxAttempts: Int,
        delay: TimeInterval,
        status: Int?,
        category: String? = nil,
        raw: Data = Data(),
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.scope = scope
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.status = status
        self.category = category
        self.raw = raw
        self.uuid = uuid
        self.sessionID = sessionID
    }

    /// What went wrong, diagnosed from the status code.
    public var trouble: RetryTrouble { RetryTrouble.diagnose(status: status, category: category) }

    /// How far through its patience the run is. See `RetryPatience`.
    public var patience: RetryPatience {
        RetryPatience.of(attempt: attempt, maxAttempts: maxAttempts)
    }

    // MARK: What it says

    /// The line in the row's label column: what went wrong, in Bloom's words.
    public var headline: String { trouble.headline }

    /// The sentence under it: what the run is doing, and whether any of it is the reader's to do
    /// something about.
    ///
    /// **The attempt count is deliberately not in it.** It was, and read against the drawing it
    /// was one figure twice: "Attempt 5 of 10." opening a sentence that sits directly under
    /// "5 of 10". The count belongs where it can be glanced at without reading, and the sentence
    /// belongs to what the count cannot say.
    ///
    /// The status code is not in it either. A person who wants the number can hover the row; a
    /// person watching a turn does not need to be taught HTTP to find out it is not their fault.
    public var note: String {
        "\(patience.counsel(canAct: trouble.isWorthActingOn)) \(trouble.counsel)"
    }

    /// The whole of it in one line, for a surface with no room to draw a counter of its own.
    public var summary: String { "\(progress) \(note)" }

    /// "Attempt 3 of 10." Its own property because it is the one part of the row that changes
    /// every time, which is what stops the surface reading as frozen.
    public var progress: String { "Attempt \(attempt) of \(maxAttempts)." }

    /// How long until the next attempt, in words, or nothing when saying it would be noise.
    ///
    /// **No ticking countdown, deliberately.** `retry_delay_ms` would support one to the
    /// millisecond, and a number counting down invites you to watch it end. What it ends at is not
    /// the answer arriving, only the next attempt at asking, so a countdown promises a moment that
    /// will most likely bring another countdown. The attempt number is the honest progress figure
    /// and it moves on its own; the drain under the row carries the wait itself as a shape. What
    /// is left for words is the order of magnitude, which is what somebody deciding whether to go
    /// and do something else actually wants.
    ///
    /// Nothing at all under five seconds. The first backoffs measured are 0.6 and 1.1 seconds:
    /// a sentence about them would be replaced before it had been read.
    public var waitPhrase: String? {
        guard delay >= 5 else { return nil }
        return "Next attempt in about \(Self.coarse(delay))."
    }

    /// A duration rounded until it stops pretending to be precise.
    static func coarse(_ seconds: TimeInterval) -> String {
        if seconds >= 90 {
            let minutes = (seconds / 60).rounded()
            return minutes == 1 ? "a minute" : "\(Int(minutes)) minutes"
        }
        let step: Double = seconds < 20 ? 5 : 10
        let rounded = max(step, (seconds / step).rounded() * step)
        return "\(Int(rounded)) seconds"
    }

    // MARK: Decoding

    /// A `system`/`api_retry` line: the turn itself is retrying.
    public static func turnRetry(_ json: JSONValue, raw: Data) -> AgentRetry {
        AgentRetry(
            scope: .turn,
            attempt: json["attempt"]?.intValue ?? 1,
            maxAttempts: json["max_retries"]?.intValue ?? 0,
            delay: milliseconds(json["retry_delay_ms"]),
            status: json["error_status"]?.intValue,
            category: json["error"]?.stringValue,
            raw: raw,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        )
    }

    /// A `tool_progress` line carrying a `subagent_retry` block, or nil when it carries none.
    ///
    /// Most `tool_progress` lines are an elapsed-seconds tick and say nothing about trouble, so
    /// this declines rather than inventing an attempt zero for them.
    public static func subagentRetry(_ json: JSONValue, raw: Data) -> AgentRetry? {
        guard let block = json["subagent_retry"], let agentID = block["agent_id"]?.stringValue
        else { return nil }
        return AgentRetry(
            scope: .subagent(
                agentID: agentID,
                // `parent_tool_use_id`, not `tool_use_id`. The first is the Agent call the
                // transcript drew a row for and is the id a `task_notification` reports the same
                // subagent's failure under; the second is an inner message id that appears
                // nowhere else. Keying on the inner one would file every retry under a row that
                // does not exist.
                toolUseID: json["parent_tool_use_id"]?.stringValue ?? json["tool_use_id"]?.stringValue,
                kind: json["subagent_type"]?.stringValue
            ),
            attempt: block["attempt"]?.intValue ?? 1,
            maxAttempts: block["max_retries"]?.intValue ?? 0,
            delay: milliseconds(block["retry_delay_ms"]),
            status: block["error_status"]?.intValue,
            category: block["error_category"]?.stringValue,
            raw: raw,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        )
    }

    private static func milliseconds(_ value: JSONValue?) -> TimeInterval {
        guard let ms = value?.doubleValue, ms > 0 else { return 0 }
        return ms / 1000
    }
}

// MARK: - RetryTrouble

/// What is behind a retry, worked out from the status code rather than from the CLI's prose.
///
/// The same standard `WorkspaceStartTrouble` sets: diagnose rather than parse, and every sentence
/// says whether there is anything the reader can do. The status code is the fact here, and it is a
/// number rather than a sentence, so there is nothing to parse in the ordinary case. The CLI's own
/// word (`overloaded`) is read only when no status arrived at all, because a category with no
/// status is the CLI describing a request that never got an answer, and that is worth telling
/// apart from a request that got one.
///
/// **529 is the case this was written for.** It is not in anybody's HTTP table and it is easy to
/// mistake for one of the client-error codes: it means the model capacity is full, which is the
/// one flavour of failure that is neither your account, your prompt nor your machine.
public enum RetryTrouble: Sendable, Hashable {
    /// 529. Capacity, at their end.
    case overloaded
    /// 429. This account has run into its allowance.
    case rateLimited
    /// Any other 5xx. Theirs, whatever it is.
    case serverFault(Int)
    /// A 4xx that is not 429. The request itself was not acceptable, and waiting may not fix it.
    case refused(Int)
    /// No status at all: nothing came back to have one.
    case unreachable
    /// A status Bloom has no reading of, kept as a number rather than guessed at.
    case unexplained(Int)

    public static func diagnose(status: Int?, category: String?) -> RetryTrouble {
        guard let status else {
            // No answer came back. The CLI's own word is all there is, and only two of them mean
            // anything Bloom can say a sentence about.
            switch category?.lowercased() {
            case "overloaded": return .overloaded
            case "rate_limit", "rate_limited": return .rateLimited
            default: return .unreachable
            }
        }
        switch status {
        case 529: return .overloaded
        case 429: return .rateLimited
        case 500...599: return .serverFault(status)
        case 400...499: return .refused(status)
        default: return .unexplained(status)
        }
    }

    /// The row's label: what went wrong, said as a state of the world rather than as a code.
    public var headline: String {
        switch self {
        case .overloaded: "Anthropic's API is overloaded"
        case .rateLimited: "Anthropic's API is rate limiting this account"
        case .serverFault: "Anthropic's API is failing"
        case .refused: "Anthropic's API refused the request"
        case .unreachable: "Bloom cannot reach Anthropic's API"
        case .unexplained: "Anthropic's API returned an error"
        }
    }

    /// Whose it is, and whether the reader has anything to do about it.
    ///
    /// The default answer is no, and it is said out loud rather than left to be inferred. Somebody
    /// watching a turn that has stopped producing output assumes they have broken something,
    /// and for the two commonest cases here the truthful answer is the reassuring one.
    public var counsel: String {
        switch self {
        case .overloaded:
            return "It is capacity at their end, not anything here."
        case .rateLimited:
            return "It is this account's allowance rather than a fault. What is left of it is in "
                + "the menu bar."
        case .serverFault(let status):
            return "It is a fault at their end (\(status)), not anything here."
        case .refused(let status):
            return "It came back as \(status), which waiting does not usually clear. If every "
                + "attempt goes the same way the turn stops and says so."
        case .unreachable:
            return "Nothing came back at all, which can be this machine's network as easily as "
                + "theirs. Worth a glance at your connection."
        case .unexplained(let status):
            return "It came back as \(status), which Bloom has no reading of."
        }
    }

    /// Whether the reader could usefully do something. False for the ones that are somebody
    /// else's weather, which is most of them.
    public var isWorthActingOn: Bool {
        switch self {
        case .overloaded, .rateLimited, .serverFault: false
        case .refused, .unreachable, .unexplained: true
        }
    }
}

// MARK: - RetryPatience

/// How far into its ten attempts a run has got, in the three sizes that call for different words.
///
/// Attempt 1 of 10 six hundred milliseconds in and attempt 9 of 10 two and a half minutes in are
/// not the same situation and must not read the same. The first is not worth interrupting anybody
/// for; the second is a turn that will probably fail, and somebody deciding whether to keep
/// waiting deserves to be told which one they are looking at.
///
/// Three bands rather than a number, because the words and the tint both step rather than slide,
/// and because the CLI is free to ship a different `max_retries` tomorrow: a rule stated in
/// fractions survives that, and one stated in "attempt 8" does not.
public enum RetryPatience: Sendable, Hashable, Comparable {
    /// It has only just started. Not news.
    case settling
    /// It has been at this a while. Still fine, still nothing to do.
    case persisting
    /// One or two attempts left, and then the turn stops.
    case lastChances

    /// The band an attempt falls in.
    ///
    /// The last two attempts are always `lastChances`, whatever the ceiling, because "the next one
    /// is the last one" is the fact that changes what a person does. Below that, the first third
    /// is `settling`. A run with no stated ceiling (`maxAttempts` zero, which no measured line has
    /// but a future one might) is `persisting` from the first attempt: without a ceiling there is
    /// no last chance to warn about, and calling it settled would be a promise nobody made.
    public static func of(attempt: Int, maxAttempts: Int) -> RetryPatience {
        guard maxAttempts > 0 else { return .persisting }
        if attempt >= maxAttempts - 1 { return .lastChances }
        if attempt * 3 <= maxAttempts { return .settling }
        return .persisting
    }

    /// What the run itself is doing, and what that asks of the reader.
    ///
    /// `canAct` comes from the trouble rather than from here, so the one band that tells somebody
    /// to sit still does not do it over the top of a diagnosis that says otherwise.
    public func counsel(canAct: Bool) -> String {
        switch self {
        case .settling:
            return canAct
                ? "Trying again by itself."
                : "Trying again by itself, with nothing for you to do."
        case .persisting:
            return canAct
                ? "Still trying, with longer waits between attempts."
                : "Still trying by itself, with longer waits between attempts."
        case .lastChances:
            return "Nearly out of attempts. If the last one fails the turn stops here and you "
                + "can send it again."
        }
    }

    /// Whether this is worth saying anywhere other than the transcript.
    ///
    /// A turn that has been retrying since before you looked away is the case that cost three
    /// minutes: the transcript is the wrong place to say it, because the person is on another pane
    /// or another workspace by then. The first third of a run is not worth anybody's attention and
    /// must not spend any.
    public var deservesNoticeElsewhere: Bool { self != .settling }
}

// MARK: - RetryRun

/// One unbroken run of retries against the same request, and what is said about it afterwards.
///
/// The attempts arrive as separate events and are one fact, so they are folded into one value as
/// they come. That fold is what lets the transcript draw one row that updates rather than ten rows
/// that accumulate, and it is what makes an answer to the question the row leaves behind: when the
/// wait finally ends, the run has a past tense.
///
/// **A settled run does not vanish and does not stay loud.** Vanishing loses the only explanation
/// for why a turn took three minutes; leaving the live row in place puts a warning tint on a turn
/// that is fine. So it collapses to one quiet sentence under the turn it happened in. A run that
/// ended in failure says nothing at all, because the error row above it is already saying it, and
/// two surfaces explaining one outage is the clutter this is trying to avoid.
public struct RetryRun: Sendable, Hashable {
    public private(set) var latest: AgentRetry
    /// The highest attempt seen. Not `latest.attempt`, because the CLI is free to restart its
    /// count on a fresh request inside the same turn and the record should keep the worst of it.
    public private(set) var attempts: Int
    /// When the first attempt of this run was seen, so a surface can say how long it has been at it.
    public let startedAt: Date

    public init(_ retry: AgentRetry, at now: Date = Date()) {
        self.latest = retry
        self.attempts = retry.attempt
        self.startedAt = now
    }

    /// Folds one more announcement into the run.
    public mutating func absorb(_ retry: AgentRetry) {
        latest = retry
        attempts = max(attempts, retry.attempt)
    }

    public var trouble: RetryTrouble { latest.trouble }
    public var patience: RetryPatience { latest.patience }

    /// The one line left behind once the wait is over and the turn carried on regardless.
    ///
    /// Past tense, no count of the attempts that came to nothing beyond the number itself, and no
    /// advice: it is a note about something that is finished. It exists because a turn whose
    /// footer says three minutes and whose transcript shows nothing in that time is a turn nobody
    /// can account for a week later.
    public var recoveredSentence: String {
        let count = attempts == 1 ? "1 attempt" : "\(attempts) attempts"
        switch trouble {
        case .overloaded:
            return "Anthropic's API was overloaded. This turn got through on attempt \(attempts) of \(latest.maxAttempts)."
        case .rateLimited:
            return "Anthropic's API was rate limiting this account. This turn got through after \(count)."
        default:
            return "\(trouble.headline). This turn got through after \(count)."
        }
    }
}
