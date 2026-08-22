import Foundation
import Synchronization

/// Bytes in, whole lines out. One per stream, because a read boundary lands wherever the kernel
/// put it and half a JSON frame is not a frame.
///
/// `Mutex` rather than `NSLock` plus `@unchecked Sendable`, for the reason given on `EventFanout`
/// in `SessionRunner`.
final class LineBuffer: Sendable {
    private let pending = Mutex(Data())

    func take(_ data: Data) -> [String] {
        pending.withLock { pending in
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
}
