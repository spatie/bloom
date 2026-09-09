import Foundation

/// A quiet script must publish its last line even when it then waits minutes for a download.
/// The timer flushes dirty output at most four times a second, independently of incoming lines.
actor SetupOutputBuffer {
    private let store: Store
    private let workspaceID: WorkspaceID
    private let attempt: UUID?
    private var log = ""
    private var length = 0
    private var dirty = false

    init(store: Store, workspaceID: WorkspaceID, attempt: UUID?) {
        self.store = store
        self.workspaceID = workspaceID
        self.attempt = attempt
    }

    func append(_ line: String) {
        let text = line + "\n"
        log += text
        length += text.count
        if length > Workspace.setupLogLimit {
            log.removeFirst(length - Workspace.setupLogLimit)
            length = Workspace.setupLogLimit
        }
        dirty = true
    }

    func snapshot() -> String { log }

    func flush() async {
        guard dirty, let attempt else { return }
        dirty = false
        try? await store.recordSetupOutput(workspaceID: workspaceID, attempt: attempt, log: log)
    }
}
