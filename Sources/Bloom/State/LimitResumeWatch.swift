import Foundation
import BloomCore

/// One chat waiting out a spent allowance, and the continuation it sends when the allowance is back.
///
/// Owned by the chat's `TranscriptModel` and gone with it, so archiving a workspace or closing the
/// chat cancels the wait rather than leaving a timer that sends into a conversation nobody can see.
/// The timer itself is not persisted; `TranscriptModel` saves the wait so the next launch arms a
/// new one. Every decision is `LimitResume`'s, in the core; this is the clock and the send.
@MainActor
@Observable
final class LimitResumeWatch {
    private(set) var step: LimitResume.Step?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isArmed: Bool { task != nil }

    /// Starts waiting. `quotas` is read on every look rather than captured, because the point is to
    /// see the readings that arrive after this was pressed. `remember` hears the wait on the first
    /// look and again whenever it learns a reset, which reaches `app.quotas` through the store's
    /// observer and so can come after the arm. Awaited in the loop, so the writes land in order.
    func arm(
        _ resume: LimitResume,
        quotas: @escaping @MainActor () -> [AgentQuota],
        refresh: @escaping @MainActor () async -> Void,
        remember: @escaping @MainActor (LimitResume) async -> Void,
        send: @escaping @MainActor () async -> Void
    ) {
        cancel()
        var first = resume
        step = first.step(quotas: quotas(), at: Date())
        task = Task { [weak self] in
            var resume = resume
            var hasRemembered = false
            var remembered: Date?
            while !Task.isCancelled {
                let next = resume.step(quotas: quotas(), at: Date())
                if !hasRemembered || resume.notBefore != remembered {
                    hasRemembered = true
                    remembered = resume.notBefore
                    await remember(resume)
                }
                if self?.step != next { self?.step = next }
                switch next {
                case .go:
                    // Cleared before the send, because sending cancels any armed resume and this
                    // is the send.
                    self?.task = nil
                    self?.step = nil
                    await send()
                    return
                case .checking:
                    // Past the reset and waiting on a reading. The app's own asker takes this as a
                    // hint and keeps its floor, so a chat checking cannot hammer the endpoint.
                    await refresh()
                case .waitUntil:
                    break
                }
                try? await Task.sleep(for: .seconds(LimitResume.interval))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if step != nil { step = nil }
    }
}
