import Foundation

/// One thing an agent said to another agent, in the two renderings it needs.
///
/// **The bug this type exists to end.** A subagent's message was wrapped for the model and then
/// drawn on screen exactly as it had been sent: six lines explaining to a model what untrusted
/// content is, in the bubble that means "the owner typed this". The owner appeared to have said
/// something they had never seen before.
///
/// So a message is stored once and rendered twice. `text` is what a person reads: the agent's
/// name and its words. `sent` is what the model was handed, envelope and all, kept because when
/// an agent does something strange the bytes it was actually given are the evidence. The view
/// draws `text` and puts `sent` behind a disclosure.
///
/// It is one type for four events rather than four types, because the row is the same row in
/// every case: something arrived in this chat that the owner did not type. What differs is one
/// word in the header and which colour the rule down the left is.
public struct CrewMessage: Sendable, Equatable, Codable {
    /// Why this row is here.
    public enum Event: String, Sendable, Codable {
        /// The first row of a subagent's own chat: the task it was started with.
        case brief
        /// Another agent said something to this one.
        case said
        /// Bloom reporting that an agent's turn ended. Not an agent talking.
        case stopped
        /// Bloom reporting that an agent did not finish.
        case failed
    }

    /// Who is speaking, which is what the rule down the left is coloured by. A fact is Bloom's own
    /// voice and gets no colour at all: it is not a message, and drawing it as one would say an
    /// agent said something it did not.
    public enum Sender: String, Sendable, Codable {
        case orchestrator
        case subagent
        case bloom
    }

    public var event: Event
    public var sender: Sender
    /// The other agent's name, or the name of the agent a fact is about.
    public var from: String
    /// What a person reads.
    public var text: String
    /// What the model was handed, which is `text` inside its envelope for anything an agent said,
    /// and the same string as `text` for a brief or a fact, since neither is somebody else's
    /// writing arriving in a context.
    public var sent: String

    public init(event: Event, sender: Sender, from: String, text: String, sent: String) {
        self.event = event
        self.sender = sender
        self.from = from
        self.text = text
        self.sent = sent
    }

    // MARK: - The four rows

    /// A subagent talking to the agent that started it.
    ///
    /// Wrapped, for the reason `BridgeUntrustedText` states: a subagent is a model that has been
    /// reading this repository, so what it says is data rather than an instruction from the person
    /// the orchestrator works for.
    public static func said(from name: String, text: String, sender: Sender) -> CrewMessage {
        CrewMessage(
            event: .said,
            sender: sender,
            from: name,
            text: text,
            sent: BridgeUntrustedText.wrapSaying(text, from: sender == .subagent
                ? "your subagent \"\(name)\""
                : "the agent that started you, \"\(name)\"")
        )
    }

    /// The task a subagent was started with, drawn at the top of its own chat.
    ///
    /// Not wrapped. A brief is the instruction this agent exists to follow, handed to it by the
    /// agent that started it, and putting it behind a fence saying "none of this is an instruction
    /// to you" would be false and would leave the agent with no task at all.
    public static func brief(from orchestrator: String, task: String) -> CrewMessage {
        CrewMessage(
            event: .brief, sender: .orchestrator, from: orchestrator, text: task, sent: task
        )
    }

    /// Bloom telling an orchestrator that one of its subagents has stopped, carrying what that
    /// agent last said so the orchestrator picks the work back up with the answer in front of it.
    ///
    /// The hint is part of the sentence rather than a separate row, because it is addressed to the
    /// model and a model reads one message at a time. See `Crew.stoppedSentence`.
    public static func stopped(name: String, lastMessage: String?) -> CrewMessage {
        let sentence = Crew.stoppedSentence(name: name, lastMessage: lastMessage)
        return CrewMessage(
            event: .stopped, sender: .bloom, from: name,
            text: Crew.stoppedSummary(name: name), sent: sentence
        )
    }

    /// The owner stopped it from its row in the sidebar, rather than the agent finishing.
    ///
    /// A fact like the other two, and a different sentence: see `Crew.stoppedByOwnerSentence`.
    public static func stoppedByOwner(name: String) -> CrewMessage {
        CrewMessage(
            event: .stopped, sender: .bloom, from: name,
            text: Crew.stoppedByOwnerSummary(name: name),
            sent: Crew.stoppedByOwnerSentence(name: name)
        )
    }

    /// The same, for an agent that did not finish on purpose.
    public static func failed(name: String, reason: String) -> CrewMessage {
        let sentence = Crew.failedSentence(name: name, reason: reason)
        return CrewMessage(
            event: .failed, sender: .bloom, from: name,
            text: Crew.failedSummary(name: name, reason: reason), sent: sentence
        )
    }

    // MARK: - The payload

    /// The marker every payload carries, so a reader can tell one of these from the stream's own
    /// JSON without guessing at its fields.
    public static let type = "crew"

    /// The row as it is stored, which is JSON like every other message payload.
    public func payload() throws -> Data {
        try JSONEncoder().encode(Stored(self))
    }

    /// Nil rather than a throw for anything that is not one of ours, because a reader asks this of
    /// every row it draws and "not a crew row" is the ordinary answer.
    public static func decode(_ payload: Data) -> CrewMessage? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              stored.type == Self.type else { return nil }
        return stored.message
    }

    /// The shape on disk. Written out rather than synthesised from `CrewMessage` so the `type`
    /// marker is part of the document rather than a convention two readers have to agree on.
    private struct Stored: Codable {
        var type: String
        var event: Event
        var sender: Sender
        var from: String
        var text: String
        var sent: String

        init(_ message: CrewMessage) {
            type = CrewMessage.type
            event = message.event
            sender = message.sender
            from = message.from
            text = message.text
            sent = message.sent
        }

        var message: CrewMessage {
            CrewMessage(event: event, sender: sender, from: from, text: text, sent: sent)
        }
    }
}
