import Foundation
import Synchronization
#if os(Linux)
import Glibc
#endif

/// Native filesystem notifications invalidate review snapshots. The cache also performs a
/// periodic full refresh, including when watch limits or unsupported filesystems lose events.
final class ServerReviewWatch: Sendable {
    private final class Counter: Sendable { let value = Mutex<UInt64>(0) }
    private let counter = Counter()
    var generation: UInt64 { counter.value.withLock { $0 } }
#if os(Linux)
    // Dispatch sources are thread-safe; all ownership changes are protected by the mutex.
    private struct State: @unchecked Sendable {
        var source: (any DispatchSourceRead)?
        var directories: [String: Int32] = [:]
    }
    private let state = Mutex(State())
    private let roots: [String]
    private let queue = DispatchQueue(label: "bloom.server.review.watch", qos: .utility)
    private let descriptor: Int32
    private let complete = Mutex(true)
    var isReliable: Bool { complete.withLock { $0 } }

    init(roots: [String]) {
        self.roots = roots
        descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { complete.withLock { $0 = false }; return }
        rebuild()
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let fd = descriptor
        source.setCancelHandler { close(fd) }
        state.withLock { $0.source = source }
        source.resume()
    }

    private func rebuild() {
        var paths = Set(roots)
        for root in roots {
            guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { walk.skipDescendants(); continue }
                guard values?.isDirectory == true else { continue }
                // Object contents cannot change a diff until a ref/index changes, both watched.
                if url.lastPathComponent == "objects", url.deletingLastPathComponent().lastPathComponent == ".git" { walk.skipDescendants(); continue }
                paths.insert(url.path)
                if paths.count >= 4_096 { complete.withLock { $0 = false }; break }
            }
        }
        state.withLock { state in
            for (path, wd) in state.directories where !paths.contains(path) {
                _ = inotify_rm_watch(descriptor, wd)
                state.directories[path] = nil
            }
            for path in paths {
                let mask = UInt32(IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF)
                let wd = inotify_add_watch(descriptor, path, mask)
                if wd < 0 { complete.withLock { $0 = false } } else { state.directories[path] = wd }
            }
        }
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var changed = false
        var directoriesChanged = false
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset + 16 <= count {
                    let mask = buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                    let length = Int(buffer.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                    if mask & UInt32(IN_IGNORED) == 0 { changed = true }
                    if mask & UInt32(IN_Q_OVERFLOW) != 0 { complete.withLock { $0 = false }; directoriesChanged = true }
                    if mask & UInt32(IN_ISDIR | IN_DELETE_SELF | IN_MOVE_SELF) != 0 { directoriesChanged = true }
                    offset += 16 + length
                }
            }
        }
        if changed { counter.value.withLock { $0 &+= 1 } }
        if directoriesChanged { rebuild() }
    }

    func stop() { state.withLock { $0.source?.cancel(); $0.source = nil } }
    deinit { state.withLock { $0.source?.cancel() } }
#else
    private let watcher: WorktreeWatcher
    var isReliable: Bool { true }
    init(roots: [String]) {
        let counter = self.counter
        watcher = WorktreeWatcher { _ in counter.value.withLock { $0 &+= 1 } }
        watcher.watch(roots: roots)
    }
    func stop() { watcher.stop() }
#endif
}
