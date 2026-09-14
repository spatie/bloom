import Foundation

extension Git {
    static func diffFiles(arguments: [String], worktree: String, layer: ChangeLayer? = nil) async throws -> [ChangedFile] {
        let options = ["diff", "--no-ext-diff", "--no-textconv", "-M", "-z"]
        async let names = checkRaw(options + ["--name-status"] + arguments + ["--"], in: worktree)
        async let stats = checkRaw(options + ["--numstat"] + arguments + ["--"], in: worktree)
        let changes = try await parseNameStatus(names.stdout)
        var files = try await parseNumstat(stats.stdout, changes: changes)
        // Mode-only changes need a row even if the numstat stream has no line counts.
        for (path, change) in changes where files[path] == nil {
            files[path] = ChangedFile(path: path, oldPath: change.1, change: change.0)
        }
        return files.values.sorted { $0.path < $1.path }.map {
            var file = $0
            file.layer = layer
            return file
        }
    }

    public static func uncommittedFiles(worktree: String) async throws -> [ChangedFile] {
        // --cached with no revision works before the repository's first commit too.
        async let headRead = try? check(["rev-parse", "--verify", "HEAD"], in: worktree)
        async let staged = diffFiles(arguments: ["--cached"], worktree: worktree, layer: .staged)
        async let unstaged = diffFiles(arguments: [], worktree: worktree, layer: .unstaged)
        async let unknown = checkRaw(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
        async let index = checkRaw(["ls-files", "--stage", "-z"], in: worktree)
        var conflicts: Set<String> = []
        var stagingRevisions: [String: String] = [:]
        for record in try await nulRecords(index.stdout) {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let path = String(decoding: record.suffix(from: record.index(after: tab)), as: UTF8.self)
            let fields = String(decoding: record.prefix(upTo: tab), as: UTF8.self).split(separator: " ")
            guard fields.count == 3 else { continue }
            if fields[2] == "0" { stagingRevisions[path] = String(fields[0]) + ":" + String(fields[1]) } else { conflicts.insert(path) }
        }
        let head = await headRead?.trimmed ?? "unborn"
        let tracked = try await staged + unstaged
        var files = conflicts.sorted().map { ChangedFile(path: $0, change: .modified, layer: .conflicted) }
        files += tracked.filter { !conflicts.contains($0.path) }.map {
            var file = $0
            file.stagingRevision = (file.layer == .staged ? head + ":" : "") + (stagingRevisions[file.path] ?? "missing")
            return file
        }
        for record in try await nulRecords(unknown.stdout) {
            let path = String(decoding: record, as: UTF8.self)
            guard !path.isEmpty else { continue }
            let full = (worktree as NSString).appendingPathComponent(path)
            let data = try? Data(contentsOf: URL(fileURLWithPath: full))
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            files.append(ChangedFile(
                path: path, change: .untracked, additions: text.map(countLines) ?? 0,
                isBinary: data?.contains(0) == true || (data != nil && text == nil), layer: .untracked
            ))
        }
        return files
    }
}
