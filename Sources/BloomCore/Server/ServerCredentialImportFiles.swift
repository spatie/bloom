import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Bounded, no-follow file access is invoked only by explicit import, never discovery.
enum ServerCredentialImportFiles {
    static func canonicalDirectory(_ path: URL) -> URL? {
        guard let resolved = realpath(path.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func isRegularOwnedFile(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
    }

    final class Folder {
        private let descriptor: Int32

        init(_ path: URL) throws {
            guard path.path == ServerCredentialImportFiles.canonicalDirectory(path)?.path else {
                throw ServerCredentialImport.failure("The credential directory changed or contains a symbolic link.")
            }
            var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard current >= 0 else { throw ServerCredentialImport.failure("The credential directory could not be opened.") }
            do {
                for component in path.pathComponents where component != "/" {
                    let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw ServerCredentialImport.failure("The credential directory could not be opened safely.") }
                    SystemCalls.close(current); current = next
                }
                var info = stat()
                guard fstat(current, &info) == 0, info.st_uid == getuid() else {
                    throw ServerCredentialImport.failure("The credential directory belongs to a different account.")
                }
                descriptor = current
            } catch { SystemCalls.close(current); throw error }
        }

        deinit { SystemCalls.close(descriptor) }

        func contains(_ name: String) throws -> Bool {
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw ServerCredentialImport.failure("The credential file could not be inspected.") }
            return false
        }

        func read(_ name: String, limit: Int) throws -> Data {
            guard !name.contains("/"), name != ".", name != ".." else { throw ServerCredentialImport.failure("The credential filename is not valid.") }
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw ServerCredentialImport.failure("The credential file could not be read safely.") }
            defer { SystemCalls.close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= limit else {
                throw ServerCredentialImport.failure("The credential file has an unsupported owner, type or size.")
            }
            var result = Data()
            while true {
                var bytes = [UInt8](repeating: 0, count: min(8192, limit + 1 - result.count))
                let count = SystemCalls.read(file, &bytes, bytes.count)
                if count == 0 { return result }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ServerCredentialImport.failure("The credential file could not be read safely.")
                }
                guard result.count + count <= limit else { throw ServerCredentialImport.failure("The credential file is too large to import.") }
                result.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    static func read(_ path: URL, limit: Int) throws -> Data {
        try Folder(path.deletingLastPathComponent()).read(path.lastPathComponent, limit: limit)
    }

    static func checkCodexStorage(_ home: Folder) throws {
        guard try home.contains("config.toml") else { return }
        do {
            let data = try home.read("config.toml", limit: 65536)
            guard let text = String(data: data, encoding: .utf8) else { throw ServerCredentialImport.failure("Codex's storage configuration is not valid.") }
            let config = try TOML.parse(text)
            if let storage = config["cli_auth_credentials_store"], storage.stringValue != "file" {
                throw ServerCredentialImport.Failure(message: "Codex is not configured to use file-based credentials.", recovery: "Use Sign In on the server. Bloom does not extract Keychain credentials or export a potentially stale auth.json cache.")
            }
        } catch let error as ServerCredentialImport.Failure { throw error } catch {
            throw ServerCredentialImport.failure("Codex's storage configuration could not be checked.")
        }
    }

    static func validCodexCache(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 131072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"]) else { return false }
        if let mode = object["auth_mode"] as? String, !["apikey", "chatgpt"].contains(mode) { return false }
        if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { return key.utf8.count <= 8192 }
        guard let tokens = object["tokens"] as? [String: Any] else { return false }
        return ["access_token", "refresh_token", "id_token"].allSatisfy { key in
            guard let token = tokens[key] as? String else { return false }
            return !token.isEmpty && token.utf8.count <= 32768
        }
    }
}
