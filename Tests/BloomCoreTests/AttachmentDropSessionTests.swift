import Synchronization
import Testing
@testable import BloomCore

@Suite("Attachment drop destination lifetime")
@MainActor
struct AttachmentDropSessionTests {
    @Test("A delayed file promise cannot write or report failures after its target closes")
    func closedTarget() {
        let target = AttachmentDropSession()
        var received = 0
        var failures = 0
        let deliveredFile = { target.deliver { received += 1 } }
        let deliveredFailure = { target.deliver { failures += 1 } }
        target.cancelAll()
        deliveredFile()
        deliveredFailure()
        #expect(received == 0)
        #expect(failures == 0)
    }

    @Test("Reopening the composer never reactivates promises from its discarded draft")
    func reopenedTarget() {
        let previous = AttachmentDropSession()
        previous.cancelAll()
        let current = AttachmentDropSession()
        var received: [String] = []
        previous.deliver { received.append("discarded") }
        current.deliver { received.append("current") }
        #expect(received == ["current"])
        #expect(!previous.isActive)
        #expect(current.isActive)
    }

    @Test("Loads queued before a target closes are cancelled before doing work")
    func queuedLoad() async {
        let target = AttachmentDropSession()
        let ran = Mutex(false)
        let queued = target.start { ran.withLock { $0 = true } }
        target.cancelAll()
        await queued?.value
        #expect(!ran.withLock { $0 })
    }
}
