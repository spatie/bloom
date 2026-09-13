import BloomClient
import Foundation

/// Read Git objects directly. No checkout means no hooks, submodules or clean/smudge filters
/// can run. HTTPS collections use no inherited credential helpers or SSH commands. GitHub alone may
/// use the installed GitHub CLI through a fixed, host-scoped helper.
struct ServerSkillsGit: Sendable {
    struct Snapshot: Sendable { var commit: String; var files: [ServerSkillFile] }

    static func validate(repository: String, ref: String) throws {
        guard let url = URLComponents(string: repository), url.scheme == "https", let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, !url.path.isEmpty, repository.utf8.count <= 1_024,
              ref.utf8.count <= 180, !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains(".."),
              ref.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 47, 95].contains($0) }) else {
            throw ServerFailure("Use an HTTPS repository URL without credentials and a branch, tag or commit. For private GitHub collections, sign in to GitHub on the server. Other private collections can be imported from your Mac.")
        }
    }

    static func fetch(repository: String, ref: String, staging: String) async throws -> Snapshot {
        try validate(repository: repository, ref: ref)
        let directory = URL(fileURLWithPath: staging).appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        return try await withThrowingTaskGroup(of: Snapshot.self) { group in
            group.addTask { try await snapshot(repository: repository, ref: ref, directory: directory) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    guard try bytes(at: directory) <= 67_108_864 else {
                        throw ServerFailure("This collection exceeds the 64 MB Git download limit. Import selected skills from your Mac instead.")
                    }
                }
                throw ServerFailure("The skill collection download timed out. Check its URL and try again.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func snapshot(repository: String, ref: String, directory: String) async throws -> Snapshot {
        _ = try await run(["init", "--bare", "--template=", directory], directory: directory)
        // One bounded shallow fetch avoids one network round trip per supporting file.
        _ = try await run(["remote", "add", "origin", repository], directory: directory)
        _ = try await run(["fetch", "--depth=1", "--no-tags", "--no-recurse-submodules", "origin", ref], directory: directory)
        let commit = String(decoding: try await run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], directory: directory), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40 || commit.count == 64,
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ServerFailure("Git did not return a pinned commit.") }
        let tree = try await run(["ls-tree", "-r", "-z", commit], directory: directory)
        var entries: [(mode: String, hash: String, path: String)] = []
        for record in tree.split(separator: 0) {
            guard let text = String(data: Data(record), encoding: .utf8), let separator = text.firstIndex(of: "\t") else {
                throw ServerFailure("This collection contains filenames that are not UTF-8.")
            }
            let metadata = text[..<separator].split(separator: " ")
            guard metadata.count == 3 else { throw ServerFailure("Git returned an invalid collection tree.") }
            entries.append((String(metadata[0]), String(metadata[2]), String(text[text.index(after: separator)...])))
        }
        let roots = entries.filter { $0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md") }.map {
            String($0.path.dropLast("SKILL.md".count))
        }
        guard !roots.isEmpty, roots.count <= 64 else { throw ServerFailure("Choose a collection containing between 1 and 64 skills.") }
        var files: [ServerSkillFile] = []
        var total = 0
        for root in roots {
            let name = root.isEmpty ? URL(string: repository)!.deletingPathExtension().lastPathComponent : root.split(separator: "/").last.map(String.init)!
            guard ServerSkillBundlePolicy.validName(name) else { throw ServerFailure("A skill directory has an unsupported name. Use lowercase letters, digits and hyphens.") }
            for entry in entries where entry.path.hasPrefix(root) {
                guard entry.mode == "100644" || entry.mode == "100755" else {
                    throw ServerFailure("Skill bundles cannot contain symlinks, submodules or special files.")
                }
                let path = name + "/" + entry.path.dropFirst(root.count)
                try ServerSkillBundlePolicy.validate(path: path)
                guard files.count < ServerSkillBundlePolicy.maximumFiles else { throw ServerFailure("The collection contains more than 512 files.") }
                let bytes = try await run(["cat-file", "blob", entry.hash], directory: directory,
                                          limit: ServerSkillBundlePolicy.maximumFileBytes)
                total += bytes.count
                guard total <= ServerSkillBundlePolicy.maximumBytes else { throw ServerFailure("Choose a collection with at most 4 MB of skill files.") }
                files.append(.init(path: path, data: bytes, isExecutable: entry.mode == "100755"))
            }
        }
        try ServerSkillBundlePolicy.validate(files)
        return Snapshot(commit: commit, files: files)
    }

    private static func run(_ arguments: [String], directory: String, limit: Int = 2_097_152) async throws -> Data {
        guard let git = Shell.which("git") else { throw ServerFailure("Install Git on the server before importing a collection.") }
        let unsets = ["GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_CONFIG", "GIT_EXEC_PATH"]
            .flatMap { ["-u", $0] }
        let result = try await Shell.runBytes("/usr/bin/env", unsets + [git, "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
            "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "http.followRedirects=false"] + githubCredentialArguments + arguments,
            cwd: directory, env: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_CONFIG_COUNT": "0", "GIT_CONFIG_PARAMETERS": "", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
                "GIT_DIR": directory, "GIT_OBJECT_DIRECTORY": directory + "/objects",
                "GIT_ALTERNATE_OBJECT_DIRECTORIES": ""], timeout: .seconds(60), outputLimit: limit)
        guard result.status == 0 else { throw ServerFailure("The skill repository could not be read. Check the URL and revision. For private GitHub collections, sign in to GitHub on the server. Other private collections can be imported from your Mac.") }
        return result.stdout
    }

    private static var githubCredentialArguments: [String] {
        guard let path = Shell.which("gh"), path.hasPrefix("/"), !path.contains("'"), !path.contains("\\"),
              !path.contains("\n"), !path.contains("\0") else { return [] }
        return ["-c", "credential.https://github.com.helper=!'" + path + "' auth git-credential"]
    }

    private static func bytes(at path: String) throws -> Int {
        guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total = 0
        var count = 0
        for case let entry as URL in entries {
            total += try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            count += 1
            if total > 67_108_864 || count > 10_000 { return 67_108_865 }
        }
        return total
    }
}
