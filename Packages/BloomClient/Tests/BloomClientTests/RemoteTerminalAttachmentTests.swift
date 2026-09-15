import Foundation
import Testing
@testable import BloomClient

@MainActor
struct RemoteTerminalAttachmentTests {
    @Test("A retired resize failure cannot close a newer terminal attachment")
    func retiredFailureCannotCloseReplacement() async throws {
        try await checkReplacement(failing: true)
    }

    @Test("A retired resize success cannot replace the newer terminal attachment")
    func retiredSuccessCannotReplaceReplacement() async throws {
        try await checkReplacement(failing: false)
    }

    private func checkReplacement(failing: Bool) async throws {
        let old = HeldTerminalConnection(holdsResize: true)
        let current = HeldTerminalConnection(holdsResize: false)
        var opens = 0
        let attachment = RemoteTerminalAttachment {
            opens += 1
            return opens == 1 ? old : current
        }
        defer { attachment.disconnect() }
        let first = Task { try await attachment.connect(columns: 80, rows: 24) }
        await old.waitForResize()
        attachment.disconnect()
        _ = try await attachment.connect(columns: 120, rows: 40)
        await old.finishResize(failing: failing)
        await #expect(throws: CancellationError.self) { try await first.value }
        let active = try #require(attachment.connection)
        try await active.send(Data("replacement".utf8))
        #expect(await current.sent == [Data("replacement".utf8)])
        #expect(await current.isClosed == false)
        #expect(await old.isClosed)
        #expect(opens == 2)
    }

    @Test("A layout change during opening reaches the server before attachment is published")
    func openingUsesLatestSize() async throws {
        let remote = HeldTerminalConnection(holdsResize: true)
        let attachment = RemoteTerminalAttachment { remote }
        defer { attachment.disconnect() }
        let opening = Task { try await attachment.connect(columns: 80, rows: 24) }
        await remote.waitForResize()
        attachment.updateSize(columns: 120, rows: 40)
        await remote.finishResize(failing: false)
        _ = try await opening.value
        #expect(await remote.sizes == ["80x24", "120x40"])
    }

    @Test("Concurrent callers wait for the same initial resize before sending")
    func openingIsSharedUntilReady() async throws {
        let remote = HeldTerminalConnection(holdsResize: true)
        var opens = 0
        let attachment = RemoteTerminalAttachment { opens += 1; return remote }
        defer { attachment.disconnect() }
        let first = Task { try await attachment.connect(columns: 80, rows: 24) }
        await remote.waitForResize()
        #expect(attachment.connection == nil)
        let second = Task { try await attachment.connect(columns: 80, rows: 24) }
        await remote.finishResize(failing: false)
        _ = try await first.value
        _ = try await second.value
        #expect(opens == 1)
        #expect(attachment.connection != nil)
    }
}

private actor HeldTerminalConnection: RemoteTerminalConnection {
    private let holdsResize: Bool
    private var continuation: CheckedContinuation<Void, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var didResize = false
    private(set) var isClosed = false
    private(set) var sent: [Data] = []
    private(set) var sizes: [String] = []
    init(holdsResize: Bool) { self.holdsResize = holdsResize }
    func read() -> Data? { nil }
    func send(_ data: Data) throws {
        guard !isClosed else { throw ConnectionFailure("Closed fixture") }
        sent.append(data)
    }
    func resize(columns: Int, rows: Int) async throws {
        didResize = true
        sizes.append("\(columns)x\(rows)")
        guard holdsResize, sizes.count == 1 else { return }
        try await withCheckedThrowingContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func close() { isClosed = true }
    func waitForResize() async {
        if didResize { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishResize(failing: Bool) {
        if failing { continuation?.resume(throwing: ConnectionFailure("Old resize failed")) } else { continuation?.resume() }
        continuation = nil
    }
}
