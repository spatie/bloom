import Foundation

/// Incremental transcript state is independent of table views, editor focus and device size.
public struct TranscriptBuffer: Sendable {
    public private(set) var messages: [RemoteMessage] = []
    public private(set) var sequence = 0
    public private(set) var streamingText = ""
    public private(set) var isBusy = false
    public private(set) var pendingQuestions: [Data] = []
    public private(set) var queueError: String?
    public private(set) var queuedPrompts: [RemoteQueuedPrompt] = []
    public private(set) var permissionDecisions: [String: String] = [:]

    public init() {}

    public mutating func apply(_ transcript: RemoteTranscript) {
        var bySequence = Dictionary(uniqueKeysWithValues: messages.map { ($0.seq, $0) })
        for message in transcript.messages { bySequence[message.seq] = message }
        messages = bySequence.values.sorted { $0.seq < $1.seq }
        sequence = messages.last?.seq ?? 0
        streamingText = transcript.streamingText
        isBusy = transcript.isBusy
        pendingQuestions = transcript.pendingQuestions
        queueError = transcript.queueError
        queuedPrompts = transcript.queuedPrompts
        permissionDecisions = transcript.permissionDecisions
    }
}
