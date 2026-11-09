import Foundation
import Synchronization

public struct AgentLifecycleEntry: Sendable {
    public let revision: UInt64
    public let event: AgentEvent
    public let messageSeq: Int?
}

/// A temporary transport journal, not conversation storage. Store remains authoritative. Only
/// lifecycle boundaries spill here; acknowledged history is truncated and the file is removed
/// when its feed closes. Read pages and total capacity have explicit bounds.
final class AgentLifecycleSpool: Sendable {
    private enum Boundary: Codable {
        case initialized(AgentInit)
        case result(AgentResult)
        case error(AgentError)

        init?(_ event: AgentEvent) {
            switch event {
            case .initialized(let value): self = .initialized(value)
            case .result(let value): self = .result(value)
            case .error(let value): self = .error(value)
            default: return nil
            }
        }

        var event: AgentEvent {
            switch self {
            case .initialized(let value): .initialized(value)
            case .result(let value): .result(value)
            case .error(let value): .error(value)
            }
        }
    }
    private struct Record: Codable {
        let revision: UInt64
        let boundary: Boundary
        let messageSeq: Int?
    }
    private struct State {
        var file: FileHandle?
        var bytes: UInt64 = 0
        var lastRevision: UInt64 = 0
        var closed = false
        var recordCount = 0
        var offsets: [(revision: UInt64, offset: UInt64)] = []
    }
    private let state = Mutex(State())
    private let url: URL
    private let capacity: Int
    private static let maximumRecordBytes = 8 * 1_024 * 1_024

    init(capacity: Int = 64 * 1_024 * 1_024) {
        self.capacity = max(1, capacity)
        url = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-lifecycle-\(UUID().uuidString)")
    }

    static func isBoundary(_ event: AgentEvent) -> Bool { Boundary(event) != nil }

    func append(_ event: AgentEvent, revision: UInt64, messageSeq: Int?) throws {
        guard let boundary = Boundary(event) else { return }
        let data = try JSONEncoder().encode(Record(revision: revision, boundary: boundary, messageSeq: messageSeq))
        guard data.count <= Self.maximumRecordBytes else { throw Failure.capacity }
        try state.withLock { value in
            guard !value.closed, value.bytes + UInt64(data.count + 8) <= UInt64(capacity) else { throw Failure.capacity }
            if value.file == nil {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { throw Failure.unavailable }
                value.file = try FileHandle(forUpdating: url)
            }
            guard let file = value.file else { throw Failure.unavailable }
            try file.seekToEnd()
            var length = UInt64(data.count).bigEndian
            try file.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try file.write(contentsOf: data)
            if value.recordCount.isMultiple(of: 32) {
                value.offsets.append((revision, value.bytes))
            }
            value.recordCount += 1
            value.bytes += UInt64(data.count + 8)
            value.lastRevision = revision
        }
    }

    func read(after cursor: UInt64, through revision: UInt64, limit: Int = 32) throws -> [AgentLifecycleEntry] {
        try state.withLock { value in
            guard let file = value.file, value.bytes > 0 else { return [] }
            // One sparse offset per 32 boundaries bounds rescanning to a single block, even
            // when a window catches up through thousands of pages.
            var lower = 0
            var upper = value.offsets.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if value.offsets[middle].revision <= cursor { lower = middle + 1 } else { upper = middle }
            }
            let offset = lower > 0 ? value.offsets[lower - 1].offset : 0
            try file.seek(toOffset: offset)
            var output: [AgentLifecycleEntry] = []
            var pageBytes = 0
            while try file.offset() < value.bytes {
                let header = try Self.read(8, from: file)
                let length = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard length <= UInt64(Self.maximumRecordBytes) else { throw Failure.unavailable }
                let data = try Self.read(Int(length), from: file)
                let record = try JSONDecoder().decode(Record.self, from: data)
                if record.revision > revision { break }
                if record.revision > cursor {
                    if !output.isEmpty, pageBytes + data.count > Self.maximumRecordBytes { break }
                    output.append(AgentLifecycleEntry(revision: record.revision, event: record.boundary.event, messageSeq: record.messageSeq))
                    pageBytes += data.count
                    if output.count >= max(1, min(limit, 128)) || pageBytes >= Self.maximumRecordBytes { break }
                }
            }
            return output
        }
    }

    func acknowledge(through revision: UInt64) throws {
        try state.withLock { value in
            guard revision >= value.lastRevision, let file = value.file, value.bytes > 0 else { return }
            try file.truncate(atOffset: 0)
            try file.seek(toOffset: 0)
            value.bytes = 0
            value.recordCount = 0
            value.offsets = []
        }
    }

    var retainedBytes: UInt64 { state.withLock { $0.bytes } }

    func close() {
        state.withLock { value in
            value.closed = true
            try? value.file?.close()
            value.file = nil
            value.bytes = 0
            value.recordCount = 0
            value.offsets = []
        }
        try? FileManager.default.removeItem(at: url)
    }

    deinit { close() }

    private static func read(_ count: Int, from file: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try file.read(upToCount: count - data.count), !chunk.isEmpty else { throw Failure.unavailable }
            data.append(chunk)
        }
        return data
    }

    private enum Failure: Error, LocalizedError {
        case capacity, unavailable
        var errorDescription: String? {
            switch self {
            case .capacity: "The live conversation buffer is full. Bloom stopped the agent to keep its turn history consistent."
            case .unavailable: "Bloom could not preserve the live conversation updates. The agent was stopped."
            }
        }
    }
}

public enum AgentPresentationReconciliation {
    public static func permitsAutomaticDrain(isCatchingUp: Bool, isTurnRunning: Bool) -> Bool {
        !isCatchingUp && !isTurnRunning
    }
}
