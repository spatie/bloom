import Foundation

public struct GitHubRepositoryListing: Codable, Sendable, Identifiable, Equatable {
    public var nameWithOwner: String
    public var description: String?
    public var isPrivate: Bool
    public var id: String { nameWithOwner }

    enum CodingKeys: String, CodingKey {
        case nameWithOwner = "full_name"
        case description
        case isPrivate = "private"
    }
}

/// Both creation windows use the execution host's gh account. Tokens never cross the connection.
public enum GitHubRepositoryBrowser {
    public static func repositories(query: String, page: Int = 1) async throws -> [GitHubRepositoryListing] {
        guard query.utf8.count <= 256, (1...20).contains(page) else { throw ServerFailure("Use a shorter repository search.") }
        guard await GitHub.access() == .ready else { throw ServerFailure("Sign in with gh on the selected machine to browse GitHub repositories.") }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["api", term.isEmpty ? "user/repos" : "search/repositories", "--method", "GET", "-f", "per_page=50", "-f", "page=\(page)"]
        if term.isEmpty { arguments += ["-f", "sort=updated", "-f", "affiliation=owner,collaborator,organization_member"] } else {
            arguments += ["-f", "q=\(term)"]
        }
        let result = try await Shell.run("gh", arguments, cwd: FileManager.default.temporaryDirectory.path, timeout: .seconds(30))
        guard result.ok else { throw ServerFailure("Could not load GitHub repositories. \(result.stderr)") }
        let data = Data(result.stdout.utf8)
        if term.isEmpty { return try JSONDecoder().decode([GitHubRepositoryListing].self, from: data) }
        struct Search: Decodable { var items: [GitHubRepositoryListing] }
        return try JSONDecoder().decode(Search.self, from: data).items
    }

    public static func validatedName(_ input: String) throws -> String {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 100 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) }),
              parts[0].first != "-", parts[1].first != "-" else {
            throw ServerFailure("Choose a GitHub repository in owner/name form.")
        }
        return input
    }

    public static func clone(_ name: String, under root: URL) async throws -> String {
        let name = try validatedName(name)
        let destination = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
            let origin = try await Git.run(["remote", "get-url", "origin"], in: destination.path)
            guard origin.ok, ["https://github.com/\(name)", "https://github.com/\(name).git", "git@github.com:\(name).git"].contains(origin.trimmed) else {
                throw ServerFailure("This folder already belongs to a different repository.")
            }
            return destination.path
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let scratch = parent.appendingPathComponent(".bloom-clone-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try await Shell.run("gh", ["repo", "clone", name, scratch.path], cwd: parent.path,
            env: ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"], timeout: .seconds(600))
        guard result.ok else { throw ServerFailure("Could not clone the GitHub repository. \(result.stderr)") }
        try FileManager.default.moveItem(at: scratch, to: destination)
        return destination.path
    }
}
