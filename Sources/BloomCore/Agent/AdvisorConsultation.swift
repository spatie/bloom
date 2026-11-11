import Foundation

/// How a consultation of the advisor reads on the wire.
///
/// Measured on CLI 2.1.322: the call and its answer each arrive on their own `assistant` line,
/// never on a `user` one, which is why neither looks like an ordinary tool call to the decoder.
public enum AdvisorConsultation {
    public static let toolName = "advisor"
    static let callType = "server_tool_use"
    static let resultType = "advisor_tool_result"
    static let errorType = "advisor_tool_result_error"
    /// Most advisors answer in a form only the consulting model can read, so there is no advice
    /// to show and the row has to say why.
    public static let encryptedNotice = "The advice is encrypted, so only the model can read it."
    /// What the live tail says, so it does not repeat the word the row above it already carries.
    static let runningLabel = "Consulting the advisor"

    static let usageType = "advisor_message"

    static func isCall(_ block: JSONValue) -> Bool {
        block["type"]?.stringValue == callType && block["name"]?.stringValue == toolName
    }

    /// The id of the message a stored consultation belongs to, or nil for any other row. The
    /// bytes are searched before anything is parsed, because this is asked of every tool call in
    /// a turn and nearly all of them are not one.
    public static func callMessageID(payload: Data) -> String? {
        guard payload.range(of: Data(callType.utf8)) != nil,
              case .toolUse(let use)? = AgentEvent.decode(line: String(decoding: payload, as: UTF8.self)),
              use.name == toolName
        else { return nil }
        return use.messageID
    }

    /// Who advised and how much it read, from the stream line that closes one message.
    ///
    /// That `message_delta` is the only line that says so. The consultation's own two lines carry
    /// the chat model's usage, and the turn's `result` lists the last message only, which on a
    /// turn that went on working after the advice is not the one that consulted.
    public static func usageReport(in payload: Data) -> AdvisorUsageReport? {
        guard payload.range(of: Data(usageType.utf8)) != nil,
              let json = JSONValue.parse(payload),
              json["type"]?.stringValue == "stream_event",
              let messageID = json["api_message_id"]?.stringValue
        else { return nil }

        let usages = (json["event"]?["usage"]?["iterations"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == usageType }
            .map { entry in
                let usage = AgentUsage.decode(entry)
                return AdvisorUsage(
                    model: entry["model"]?.stringValue ?? "",
                    readTokens: usage.contextUsedTokens,
                    writtenTokens: usage.outputTokens
                )
            }
        return usages.isEmpty ? nil : AdvisorUsageReport(messageID: messageID, usages: usages)
    }

    /// What the row shows for an answer. A failed consultation does not fail the turn: the model
    /// carries on without advice, so the code is all there is to report.
    static func outcome(of block: JSONValue) -> (text: String, isError: Bool) {
        let content = block["content"]
        switch content?["type"]?.stringValue {
        case "advisor_result":
            return (content?["text"]?.stringValue ?? "", false)
        case errorType:
            let code = content?["error_code"]?.stringValue ?? "unknown"
            return ("Advisor unavailable (\(code))", true)
        default:
            return (encryptedNotice, false)
        }
    }
}

/// The consultations one message made, in the order they ran.
public struct AdvisorUsageReport: Hashable, Sendable {
    public let messageID: String
    public let usages: [AdvisorUsage]
}

/// What one consultation cost, which is all there is to say about advice nobody can read.
public struct AdvisorUsage: Hashable, Sendable {
    public let model: String
    /// Everything the advisor had in front of it, cached or not: the conversation so far.
    public let readTokens: Int
    public let writtenTokens: Int

    public init(model: String, readTokens: Int, writtenTokens: Int) {
        self.model = model
        self.readTokens = readTokens
        self.writtenTokens = writtenTokens
    }

    public func summary(locale: Locale = .autoupdatingCurrent) -> String {
        let figures = "\(ContextCompaction.tokens(readTokens, locale: locale)) tokens read"
            + " · \(ContextCompaction.tokens(writtenTokens, locale: locale)) written"
        return model.isEmpty ? figures : "\(ModelLabel.readable(model)) · \(figures)"
    }
}
