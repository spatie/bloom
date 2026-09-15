import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ServerReviewFileStamp {
    static func read(_ path: String) -> Data {
        var value = stat()
        guard lstat(path, &value) == 0 else { return Data("missing".utf8) }
#if os(Linux)
        let times = [value.st_mtim.tv_sec, value.st_mtim.tv_nsec, value.st_ctim.tv_sec, value.st_ctim.tv_nsec]
#else
        let times = [value.st_mtimespec.tv_sec, value.st_mtimespec.tv_nsec, value.st_ctimespec.tv_sec, value.st_ctimespec.tv_nsec]
#endif
        return Data("\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(times)\0".utf8)
    }
}
