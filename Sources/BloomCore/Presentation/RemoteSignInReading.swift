import Foundation

/// What a sign-in command running on a server has put on its terminal, read for the few things
/// the sheet can show better than the terminal can.
///
/// A local sign-in never reads its terminal (see `GitHubSignInSheet`), because the CLI opens the
/// browser itself. On a server there is no browser to open, so each CLI falls back to printing a
/// link, and the screenshot that started this showed what that means unread: npm notices, "Opening
/// browser to sign in" from a machine with no screen, and an OAuth URL wrapped over seven lines to
/// be copied by hand. The link has to cross to this Mac, and reading it is the only way it can.
/// What is read lives in the sheet for as long as the sheet does, and is never stored or logged.
///
/// The input is the rendered screen with wrapped rows already joined, which is what
/// `BloomTerminalView.renderedOutput` returns, so a URL wrapped over several rows is one line here.
/// Every field is optional in spirit: output nothing here recognises leaves them empty, and the
/// sheet shows the terminal instead.
public struct RemoteSignInReading: Sendable, Equatable {
    /// The install marker has been printed and the CLI has not started talking yet.
    public var isInstalling = false
    /// The page to open in the browser on this Mac.
    public var link: URL?
    /// A one-time code the user types into that page, for device flows.
    public var code: String?
    /// The CLI is waiting at a prompt for a code copied back from the browser.
    public var wantsPastedCode = false
    /// A code has been typed at that prompt and the CLI has not answered yet.
    public var hasPastedCode = false
    /// gh is waiting for Return before it continues to the browser step.
    public var waitsForReturn = false
    /// Something the CLI printed that reads as success. Not the verdict: the server's own account
    /// check is, because a login backed out of can still print and exit cleanly.
    public var reportsSuccess = false
    /// The last error the CLI printed, in its own words.
    public var problem: String?
    /// What to type, unasked, at a prompt whose answer is already decided.
    public var automaticReply: String?
    /// The last line looks like a question and nothing above recognises it.
    public var hasUnrecognisedPrompt = false

    public init() {}

    public init(account: RemoteSignInAccount, output: String) {
        let lines = output
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // npm prints a changelog URL and, on failure, a log path; neither is ours to open.
        let meaningful = lines.filter { !$0.isEmpty && !$0.hasPrefix("npm ") }
        let last = meaningful.last ?? ""

        let markerIndex = lines.lastIndex(of: RemoteSignInAccount.installMarker)
        let afterMarker = markerIndex.map { Array(lines[($0 + 1)...]) } ?? lines
        let spoken = afterMarker.filter { !$0.isEmpty && !$0.hasPrefix("npm ") && !Self.isNpmProgress($0) }

        link = meaningful.compactMap(Self.link(in:)).last
        code = meaningful.compactMap(Self.code(in:)).last
        if account == .github, code != nil, link == nil {
            link = URL(string: "https://github.com/login/device")
        }

        if let prompt = meaningful.last(where: { $0.hasPrefix(Self.pastePrompt) }) {
            let typed = prompt.dropFirst(Self.pastePrompt.count).trimmingCharacters(in: .whitespaces)
            let isLast = prompt == last
            wantsPastedCode = isLast && typed.isEmpty
            hasPastedCode = !typed.isEmpty || !isLast
        }
        waitsForReturn = last.contains("Press Enter")
        if last.contains("Authenticate Git with your GitHub credentials?") {
            // The command runs `gh auth setup-git` straight after, so yes is already the answer.
            automaticReply = "\r"
        }
        reportsSuccess = meaningful.contains { line in
            Self.successPhrases.contains { line.contains($0) }
        }
        problem = meaningful.last { line in
            Self.problemPhrases.contains { line.localizedCaseInsensitiveContains($0) }
        }
        isInstalling = markerIndex != nil && link == nil && spoken.isEmpty

        let recognised = wantsPastedCode || waitsForReturn || automaticReply != nil || link != nil || code != nil
        hasUnrecognisedPrompt = !recognised && !isInstalling && Self.looksLikePrompt(last)
    }

    static let pastePrompt = "Paste code here if prompted >"

    /// gh's "Authentication complete.", Claude Code's "Login successful.", Codex's
    /// "Successfully logged in".
    static let successPhrases = ["Authentication complete", "Login successful", "Successfully logged in"]

    static let problemPhrases = ["OAuth error", "Invalid code", "Error logging in", "error:", "failed", "timed out"]

    static func link(in line: String) -> URL? {
        guard let range = line.range(of: #"https://[^\s<>"']+"#, options: .regularExpression) else { return nil }
        // gh ends "Press Enter to open https://github.com/login/device in your browser..." and a
        // sentence can end on a full stop, neither of which is part of the address.
        let text = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)…"))
        return URL(string: text)
    }

    /// A one-time code: groups of capitals and digits joined by hyphens, which is the shape both
    /// gh and Codex print. A line with an address in it is skipped, because query strings are
    /// full of runs of capitals.
    static func code(in line: String) -> String? {
        guard !line.contains("://") else { return nil }
        guard let range = line.range(of: #"\b[A-Z0-9]{4,}(-[A-Z0-9]{4,})+\b"#, options: .regularExpression) else { return nil }
        let candidate = String(line[range])
        // A version number or a date has no letters; a one-time code nearly always does.
        guard candidate.contains(where: \.isLetter) else { return nil }
        return candidate
    }

    static func looksLikePrompt(_ line: String) -> Bool {
        guard let end = line.last else { return false }
        return end == "?" || end == ":" || end == ">" || line.hasSuffix("(Y/n)") || line.hasSuffix("(y/N)")
    }

    /// npm's spinner draws one character per frame and leaves it on screen.
    static func isNpmProgress(_ line: String) -> Bool {
        line.count <= 2 || line.allSatisfy { "|/-\\⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ ".contains($0) }
    }
}
