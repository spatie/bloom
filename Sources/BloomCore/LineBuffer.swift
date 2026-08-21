import Foundation

/// Bytes in, whole lines out. One per stream, because a read boundary lands wherever the kernel
/// put it and half a JSON frame is not a frame.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func take(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }
}
