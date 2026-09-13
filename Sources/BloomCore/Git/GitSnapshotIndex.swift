import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Hold Git's real index lock while restore uses a private index. Only the final atomic rename
/// publishes the captured staging state; other Git writers cannot interleave with the restore.
final class GitSnapshotIndex {
    let indexPath: String
    let lockPath: String
    private var descriptor: Int32
    private var ownsLock = false

    init(directory: String) throws {
        indexPath = (directory as NSString).appendingPathComponent("index")
        lockPath = indexPath + ".lock"
        descriptor = open(lockPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
        guard descriptor >= 0 else {
            throw SnapshotFailure("Git is updating the index. Try again when it has finished.")
        }
        ownsLock = true
    }

    func install(_ bytes: Data?) throws {
        if let bytes {
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try file.write(contentsOf: bytes)
            try file.synchronize()
            close(descriptor)
            descriptor = -1
            guard rename(lockPath, indexPath) == 0 else {
                throw SnapshotFailure("The restored Git index could not be installed.")
            }
            ownsLock = false
        } else {
            if unlink(indexPath) != 0 && errno != ENOENT {
                throw SnapshotFailure("The previous missing-index state could not be restored.")
            }
            release()
        }
    }

    func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        if ownsLock {
            ownsLock = false
            try? FileManager.default.removeItem(atPath: lockPath)
        }
    }

    deinit { release() }
}
