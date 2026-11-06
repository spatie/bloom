import Foundation

/// The commit a squash merge lands as, when the person merging wants to word it themselves.
///
/// The proposal is GitHub's own default subject, `Title (#12)`, with no body. Left as proposed,
/// nothing is added to the merge turn, so a merge nobody edited is the turn it always was.
public struct SquashCommitMessage: Sendable, Hashable {
    public var subject: String
    public var body: String

    public init(subject: String, body: String = "") {
        self.subject = subject
        self.body = body
    }

    /// `Title (#12)` on GitHub. GitLab's own default for a squash is just the title.
    public static func proposed(for pullRequest: PullRequest) -> SquashCommitMessage {
        switch pullRequest.forge {
        case .gitHub: SquashCommitMessage(subject: "\(pullRequest.title) (#\(pullRequest.number))")
        case .gitLab: SquashCommitMessage(subject: pullRequest.title)
        }
    }

    /// This message trimmed, or nil when there is nothing to ask for: left as proposed, or a
    /// subject emptied out.
    public func edited(from proposed: SquashCommitMessage) -> SquashCommitMessage? {
        let trimmed = SquashCommitMessage(
            subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.subject.isEmpty, trimmed != proposed else { return nil }
        return trimmed
    }

    /// The `gh pr merge` flags for this message. The `=` form keeps a subject starting with a
    /// dash from being read as a flag of its own.
    public var mergeArguments: [String] {
        ["--subject=\(subject)"] + (body.isEmpty ? [] : ["--body=\(body)"])
    }

    /// The whole message as `glab mr merge --squash-message` takes it: subject, blank line, body.
    public var commitMessage: String {
        body.isEmpty ? subject : "\(subject)\n\n\(body)"
    }

    /// The paragraph that asks the agent for this message, or nil when there is nothing to ask.
    public func instruction(proposed: SquashCommitMessage, forge: Forge = .gitHub) -> String? {
        guard let edited = edited(from: proposed) else { return nil }
        let subject = edited.subject
        let body = edited.body

        let fence = Self.fence(longerThanAnyIn: subject + "\n" + body)
        if forge == .gitLab {
            return "Squash with this commit message, word for word, as `--squash-message` to `glab mr merge`:\n\n"
                + "\(fence)\n\(edited.commitMessage)\n\(fence)"
        }
        guard !body.isEmpty else {
            return "Squash with this commit subject, word for word, as `--subject` to `gh pr merge`:\n\n"
                + "\(fence)\n\(subject)\n\(fence)"
        }
        return "Squash with this commit message, word for word: the first block as `--subject` and the "
            + "second as `--body` to `gh pr merge`.\n\n\(fence)\n\(subject)\n\(fence)\n\n\(fence)\n\(body)\n\(fence)"
    }

    /// A code fence the text itself cannot close.
    private static func fence(longerThanAnyIn text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
