import Foundation

/// The server a project's pull requests live on, and the few words that differ between them.
/// The raw values are what a project writes as `git.forge`.
public enum Forge: String, Sendable, Hashable, Codable {
    case gitHub = "github"
    case gitLab = "gitlab"

    /// The GitHub words are the old literals, held by the characterisation tests.
    public var request: String {
        switch self {
        case .gitHub: "pull request"
        case .gitLab: "merge request"
        }
    }

    /// `request` at the start of a sentence.
    public var titledRequest: String {
        request.prefix(1).uppercased() + request.dropFirst()
    }

    /// `PR` or `MR`, where a button has room for little else.
    public var shortRequest: String {
        switch self {
        case .gitHub: "PR"
        case .gitLab: "MR"
        }
    }

    /// The command line tool Bloom runs for this forge.
    public var cli: String {
        switch self {
        case .gitHub: "gh"
        case .gitLab: "glab"
        }
    }

    /// `gh pr merge`, `glab mr merge`.
    public func command(_ verb: String) -> String {
        "\(cli) \(self == .gitHub ? "pr" : "mr") \(verb)"
    }

    public var name: String {
        switch self {
        case .gitHub: "GitHub"
        case .gitLab: "GitLab"
        }
    }

    /// What the checks are called: GitLab shows a merge request's pipeline and its jobs.
    public var checks: String {
        switch self {
        case .gitHub: "Checks"
        case .gitLab: "Pipeline"
        }
    }

    /// `#12` on GitHub, `!12` on GitLab, where `#12` is an issue.
    public func reference(_ number: Int) -> String {
        switch self {
        case .gitHub: "#\(number)"
        case .gitLab: "!\(number)"
        }
    }
}
