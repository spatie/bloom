import Foundation

public enum SessionState: String, Sendable, Codable, CaseIterable, Hashable {
    case idle
    case running
    /// The agent asked to do something and is holding its turn open until somebody answers.
    ///
    /// Distinct from `running` because it is the opposite of running: the process is alive, the
    /// clock is going, and no work is happening. The CLI puts no timer on the question, so this
    /// state ends when a person ends it. A session in it is the one thing in Bloom that gets
    /// worse the longer it is left alone.
    case waiting
    case failed
    case cancelled
}
