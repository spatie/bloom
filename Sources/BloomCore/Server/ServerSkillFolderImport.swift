import Foundation
import BloomClient
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Reads only the folder explicitly selected by a user. Directory descriptors keep a changed
/// path or link from redirecting the upload into local credentials or another folder.
public enum ServerSkillFolderImport {
    public static func read(_ folder: URL) throws -> [ServerSkillFile] {
        let name = folder.lastPathComponent
        guard ServerSkillBundlePolicy.validName(name) else {
            throw ServerFailure("Use a skill folder named with lowercase letters, numbers and hyphens, up to 64 characters.")
        }
        let root = try ServerSkillDirectory(path: folder.standardizedFileURL.path)
        var files: [ServerSkillFile] = []
        var bytes = 0
        var entries = 0
        try walk(root, prefix: name, files: &files, bytes: &bytes, entries: &entries)
        guard files.contains(where: { $0.path == name + "/SKILL.md" }) else {
            throw ServerFailure("Choose a skill folder containing SKILL.md.")
        }
        try ServerSkillBundlePolicy.validate(files)
        return files
    }

    private static func walk(_ directory: ServerSkillDirectory, prefix: String, files: inout [ServerSkillFile],
                             bytes: inout Int, entries: inout Int) throws {
        for name in try directory.names() {
            try Task.checkCancellation()
            // Finder metadata and hidden configuration are never part of an implicit upload.
            if name.hasPrefix(".") { continue }
            entries += 1
            guard entries <= ServerSkillBundlePolicy.maximumFiles * 2 else {
                throw ServerFailure("The selected skill contains too many folders or files.")
            }
            let path = prefix + "/" + name
            try ServerSkillBundlePolicy.validate(path: path)
            var info = stat()
            guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ServerFailure("The skill folder changed while it was being read. Select it again.")
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try walk(directory.directory(name), prefix: path, files: &files, bytes: &bytes, entries: &entries)
            case S_IFREG:
                guard info.st_nlink == 1 else { throw ServerFailure("Skill imports cannot include hard-linked files: " + path) }
                let data = try directory.read(name, limit: ServerSkillBundlePolicy.maximumFileBytes)
                bytes += data.count
                guard bytes <= ServerSkillBundlePolicy.maximumBytes, files.count < ServerSkillBundlePolicy.maximumFiles else {
                    throw ServerFailure("A skill import can contain at most 512 files and 4 MB.")
                }
                files.append(ServerSkillFile(path: path, data: data, isExecutable: info.st_mode & 0o111 != 0))
            default:
                throw ServerFailure("Skill imports cannot include symbolic links or special files: " + path)
            }
        }
    }
}
