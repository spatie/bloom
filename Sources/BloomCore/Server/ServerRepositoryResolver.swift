import Foundation

/// Repository URLs are cloned on the execution host. Concurrent workspace creates share one
/// clone, and a failed clone is never mistaken for a ready checkout.
actor ServerRepositoryResolver {
    private var clones: [String: Task<String, Error>] = [:]

    func resolve(_ input: String, dataDirectory: URL) async throws -> String {
        if input.hasPrefix("/") { return input }
        guard let url = URL(string: input), ["https", "ssh"].contains(url.scheme),
              url.host != nil, url.password == nil, url.scheme != "https" || url.user == nil else {
            throw ServerFailure("Choose an absolute repository path or an HTTPS/SSH Git URL without embedded credentials.")
        }
        if let clone = clones[input] { return try await clone.value }
        let task = Task {
            let root = dataDirectory.appendingPathComponent("repositories", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
            let key = String(ServerFileOperations.revision(Data(input.utf8)).prefix(12))
            let destination = root.appendingPathComponent((name.isEmpty ? "repository" : name) + "-" + key)
            if FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) { return destination.path }
            let scratch = root.appendingPathComponent("clone-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = try await Shell.run("git", ["clone", "--", input, scratch.path], cwd: root.path,
                env: ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"], timeout: .seconds(600))
            guard result.ok else { throw ServerFailure("Could not clone the repository on the server. \(result.stderr)") }
            try FileManager.default.moveItem(at: scratch, to: destination)
            return destination.path
        }
        clones[input] = task
        defer { clones.removeValue(forKey: input) }
        return try await task.value
    }
}
