import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Resolve permitted internal symlinks once, then walk from a held workspace directory without
/// following any more links. All reads, creates and replacements use the held parent descriptor;
/// swapping a checked path for a symlink cannot redirect the actual filesystem operation.
final class WorkspaceFileAccess {
    private let parent: WorkspaceDirectoryHandle?
    private let name: String

    convenience init(workspace: Workspace, path: String, creatingParents: Bool = false,
                     followingFinalSymlink: Bool = true, allowingMissing: Bool = false) throws {
        try self.init(root: workspace.path, path: path, creatingParents: creatingParents,
                      followingFinalSymlink: followingFinalSymlink, allowingMissing: allowingMissing)
    }

    init(root rootPath: String, path: String, creatingParents: Bool = false,
         followingFinalSymlink: Bool = true, allowingMissing: Bool = false) throws {
        try ServerReview.validateRelativePath(path)
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        var directory: WorkspaceDirectoryHandle? = try WorkspaceDirectoryHandle(path: root.path)
        let target: URL
        if creatingParents {
            // Upload paths are fresh scratch paths. Following an existing scratch-directory
            // symlink would also defeat its .gitignore, even when its target is inside the repo.
            target = root.appendingPathComponent(path).standardizedFileURL
        } else if !followingFinalSymlink {
            let components = path.split(separator: "/")
            let parentPath = components.dropLast().joined(separator: "/")
            let parent = parentPath.isEmpty ? root : ContainedPath.relative(parentPath, inside: root.path)
            guard let parent, let name = components.last else { throw ServerFailure("This file is outside the workspace.") }
            target = parent.appendingPathComponent(String(name))
        } else {
            guard let resolved = ContainedPath.relative(path, inside: root.path) else {
                throw ServerFailure("This file is outside the workspace.")
            }
            target = resolved
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else { throw ServerFailure("This file is outside the workspace.") }
        let components = target.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let name = components.last, !components.contains(".."), !components.contains(".") else {
            throw ServerFailure("Use a file path inside this workspace.")
        }
        for component in components.dropLast() {
            directory = try directory?.child(component, create: creatingParents, allowingMissing: allowingMissing)
        }
        self.parent = directory
        self.name = name
    }

    func read(limit: Int) throws -> Data {
        let file = try openRegular()
        defer { close(file) }
        return try Self.read(file, limit: limit)
    }

    func replace(_ data: Data, expectedRevision: String, limit: Int) throws {
        guard let parent else { throw Self.changed }
        let original = try openRegular()
        defer { close(original) }
        // Nonblocking and per inode: two clients cannot both replace the same revision. Editors
        // outside Bloom may ignore this advisory lock, so recheck both name identity and content
        // immediately before the atomic replacement as well.
        guard flock(original, LOCK_EX | LOCK_NB) == 0 else {
            throw ServerFailure("This file is being saved elsewhere. Reload it before saving again.")
        }
        let current = try Self.read(original, limit: limit)
        guard !current.contains(0), String(data: current, encoding: .utf8) != nil else {
            throw ServerFailure("This file is binary or is not UTF-8 text.")
        }
        guard ServerFileOperations.revision(current) == expectedRevision else { throw Self.changed }
        var originalInfo = stat()
        guard fstat(original, &originalInfo) == 0 else { throw Self.changed }
        let temporary = ".bloom-write-" + UUID().uuidString
        let output = openat(parent.descriptor, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw ServerFailure("The file could not be saved in this workspace.") }
        defer { close(output); _ = unlinkat(parent.descriptor, temporary, 0) }
        try Self.write(data, to: output)
        guard fchmod(output, originalInfo.st_mode & 0o777) == 0 else { throw ServerFailure("The file permissions could not be preserved.") }
        var currentInfo = stat()
        guard fstatat(parent.descriptor, name, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0,
              currentInfo.st_dev == originalInfo.st_dev, currentInfo.st_ino == originalInfo.st_ino,
              (currentInfo.st_mode & S_IFMT) == S_IFREG,
              ServerFileOperations.revision(try Self.read(original, limit: limit)) == expectedRevision else { throw Self.changed }
        guard renameat(parent.descriptor, temporary, parent.descriptor, name) == 0 else {
            throw ServerFailure("The file moved before it could be saved. Reload it and try again.")
        }
    }

    /// Creates a new upload or its ignore file without overwriting an existing entry or following
    /// a link. An existing shield is preserved, matching WorktreeScratch's local policy.
    @discardableResult
    func create(_ data: Data, allowExisting: Bool = false, mode: mode_t = 0o600) throws -> Bool {
        guard let parent else { throw Self.changed }
        let descriptor = openat(parent.descriptor, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if descriptor < 0 {
            if allowExisting, errno == EEXIST {
                let existing = try openRegular()
                close(existing)
                return false
            }
            throw ServerFailure("The upload could not be created safely inside this workspace.")
        }
        defer { close(descriptor) }
        do {
            try Self.write(data, to: descriptor)
            guard fchmod(descriptor, mode & 0o777) == 0 else { throw ServerFailure("The file mode could not be preserved.") }
        } catch {
            _ = unlinkat(parent.descriptor, name, 0)
            throw error
        }
        return true
    }

    func snapshot(limit: Int) throws -> WorkspaceFileSnapshot {
        guard let parent else { return .missing }
        var info = stat()
        guard fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .missing }
            throw ServerFailure("The changed file moved before it could be read. Refresh and try again.")
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: 65_537)
            let length = bytes.withUnsafeMutableBytes { buffer in
                readlinkat(parent.descriptor, name, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), buffer.count)
            }
            guard length >= 0, length < bytes.count, length <= limit else { throw ServerFailure("This symbolic link could not be read safely.") }
            return .symbolicLink(Data(bytes.prefix(length)))
        }
        let descriptor = try openRegular()
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0 else { throw Self.changed }
        return .file(try Self.read(descriptor, limit: limit), mode: info.st_mode & 0o777)
    }

    func createSymbolicLink(_ target: Data) throws {
        guard let parent, !target.contains(0) else { throw ServerFailure("This symbolic link is invalid.") }
        var bytes = target
        bytes.append(0)
        let result = bytes.withUnsafeBytes { buffer in
            symlinkat(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), parent.descriptor, name)
        }
        guard result == 0 else { throw ServerFailure("The symbolic link snapshot could not be created.") }
    }

    private func openRegular() throws -> Int32 {
        guard let parent else { throw Self.changed }
        let descriptor = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ServerFailure("This file could not be opened safely. It may have moved or become a symbolic link.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ServerFailure("Only regular files can be opened.")
        }
        return descriptor
    }

    private static func read(_ descriptor: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= limit else {
            throw ServerFailure("This file exceeds the download or editor size limit.")
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw ServerFailure("This file could not be read.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= limit {
            let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw ServerFailure("The file grew beyond the download or editor size limit.") }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static var changed: ServerFailure {
        ServerFailure("This file changed on the server. Reload it before saving your edits.")
    }
}

private final class WorkspaceDirectoryHandle {
    let descriptor: Int32
    init(path: String) throws {
        descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ServerFailure("The workspace folder is unavailable.") }
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    func child(_ name: String, create: Bool, allowingMissing: Bool) throws -> WorkspaceDirectoryHandle? {
        if create, mkdirat(descriptor, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw ServerFailure("The upload folder could not be created inside this workspace.")
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            if allowingMissing, errno == ENOENT { return nil }
            throw ServerFailure("This path moved or contains a symbolic-link folder. Refresh before retrying.")
        }
        return WorkspaceDirectoryHandle(descriptor: child)
    }
}

enum WorkspaceFileSnapshot {
    case missing
    case file(Data, mode: mode_t)
    case symbolicLink(Data)

    var byteCount: Int {
        switch self {
        case .missing: 0
        case .file(let data, _), .symbolicLink(let data): data.count
        }
    }
}
