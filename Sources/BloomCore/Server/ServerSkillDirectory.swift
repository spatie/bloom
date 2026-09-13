import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Hold every parent descriptor while touching skill files. A symlink swapped into an agent's
/// configuration directory cannot redirect an import or removal outside that directory.
final class ServerSkillDirectory {
    let descriptor: Int32

    init(path: String) throws {
        guard path.hasPrefix("/") else { throw ServerFailure("Skill storage must use an absolute path.") }
        var path = path
        #if os(macOS)
        // macOS exposes system-owned /var and /tmp aliases. Resolve only those known roots;
        // user-controlled links further down the path still fail the descriptor walk.
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        #endif
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw Self.failure }
            current = next
        }
        descriptor = current
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    func directory(_ path: String, create: Bool = false) throws -> ServerSkillDirectory {
        var current = dup(descriptor)
        guard current >= 0 else { throw Self.failure }
        for name in try Self.components(path) {
            if create, mkdirat(current, name, 0o700) != 0, errno != EEXIST { close(current); throw Self.failure }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw Self.failure }
            current = next
        }
        return ServerSkillDirectory(descriptor: current)
    }

    func read(_ path: String, limit: Int) throws -> Data {
        let (parent, name) = try parent(path)
        let fd = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= limit else { throw Self.failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw Self.failure }
        }
        return data
    }

    func write(_ path: String, data: Data, replace: Bool = false, executable: Bool = false) throws {
        let (parent, name) = try parent(path, create: true)
        let temporary = ".skill-write-" + UUID().uuidString
        let target = replace ? temporary : name
        let fd = openat(parent.descriptor, target, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure }
        defer { close(fd); if replace { _ = unlinkat(parent.descriptor, temporary, 0) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fchmod(fd, executable ? 0o700 : 0o600) == 0, fsync(fd) == 0 else { throw Self.failure }
        if replace, renameat(parent.descriptor, temporary, parent.descriptor, name) != 0 { throw Self.failure }
        guard fsync(parent.descriptor) == 0 else { throw Self.failure }
    }

    func names() throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw Self.failure }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw Self.failure }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 2_048 else { throw ServerFailure("This skill directory contains too many entries to inspect safely.") }
        }
        return result.sorted()
    }

    func link(_ name: String) throws -> String? {
        _ = try Self.components(name)
        guard !name.contains("/") else { throw Self.failure }
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Self.failure
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { throw ServerFailure("An unmanaged skill already uses this name. Rename the imported skill first.") }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let size = readlinkat(descriptor, name, &buffer, buffer.count)
        guard size >= 0, size < buffer.count else { throw Self.failure }
        return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func removeFile(_ name: String) throws {
        guard !name.contains("/"), !(try Self.components(name)).isEmpty else { throw Self.failure }
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure }
        guard fsync(descriptor) == 0 else { throw Self.failure }
    }

    func publish(_ name: String, target: String) throws {
        guard !name.contains("/"), try link(name) == nil else { throw ServerFailure("An existing skill already uses this name. Nothing was overwritten.") }
        guard symlinkat(target, descriptor, name) == 0 else { throw Self.failure }
    }

    func unpublish(_ name: String, target: String) throws {
        guard let current = try link(name) else { return }
        guard current == target else { throw ServerFailure("This skill was changed outside Bloom. Its files and link were preserved.") }
        guard unlinkat(descriptor, name, 0) == 0 else { throw Self.failure }
    }

    private func parent(_ path: String, create: Bool = false) throws -> (ServerSkillDirectory, String) {
        let parts = try Self.components(path)
        let parent = parts.dropLast().joined(separator: "/")
        return (parent.isEmpty ? try directory("") : try directory(parent, create: create), parts.last!)
    }

    private static func components(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { throw failure }
        return parts
    }

    static let failure = ServerFailure("Skill storage is unavailable or contains an unsafe file or symbolic link. Check its ownership and paths.")
}
