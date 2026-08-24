import Testing
import Foundation
@testable import BloomCore

@Suite("Workspace naming")
struct WorkspaceNamingTests {
    // MARK: - The placeholder

    @Test("a placeholder never repeats a name already in use")
    func placeholderAvoidsCollisions() {
        var generator = SystemRandomNumberGenerator()
        var taken: Set<String> = []
        for _ in 0..<WorkspaceNaming.placeholders.count {
            let name = WorkspaceNaming.placeholder(avoiding: taken, using: &generator)
            #expect(!taken.contains(name))
            taken.insert(name)
        }
        #expect(taken.count == WorkspaceNaming.placeholders.count)
    }

    @Test("past the end of the list it numbers rather than repeats")
    func placeholderExhaustion() {
        var generator = SystemRandomNumberGenerator()
        let all = Set(WorkspaceNaming.placeholders)
        let overflow = WorkspaceNaming.placeholder(avoiding: all, using: &generator)
        #expect(!all.contains(overflow))
        #expect(overflow.hasSuffix(" 2"))

        let second = WorkspaceNaming.placeholder(
            avoiding: all.union([overflow]), using: &generator
        )
        #expect(second != overflow)
    }

    @Test("the list is long enough, and every entry is one plain word")
    func placeholderList() {
        #expect(WorkspaceNaming.placeholders.count >= 120)
        #expect(Set(WorkspaceNaming.placeholders).count == WorkspaceNaming.placeholders.count)
        for name in WorkspaceNaming.placeholders {
            #expect(!name.contains(" "), "\(name) is not one word")
            #expect(name.first?.isUppercase == true)
            #expect(name.allSatisfy { $0.isLetter })
        }
    }

    // MARK: - Reading the answer

    @Test("a plain answer comes through unchanged")
    func cleanNameHappyPath() {
        #expect(WorkspaceNaming.cleanName("Dark mode toggle") == "Dark mode toggle")
    }

    @Test(
        "everything a model does to a short answer is undone",
        arguments: [
            ("\"Dark mode toggle\"", "Dark mode toggle"),
            ("`Dark mode toggle`", "Dark mode toggle"),
            ("**Dark mode toggle**", "Dark mode toggle"),
            ("Dark mode toggle.", "Dark mode toggle"),
            ("Dark mode toggle:", "Dark mode toggle"),
            ("  Dark mode toggle  ", "Dark mode toggle"),
            ("Dark    mode\ttoggle", "Dark mode toggle"),
            ("\n\nDark mode toggle\nHere is why I chose it", "Dark mode toggle"),
        ]
    )
    func cleanNameNormalises(raw: String, expected: String) {
        #expect(WorkspaceNaming.cleanName(raw) == expected)
    }

    @Test("an answer that is not a name at all is refused", arguments: ["", "   ", "\n", ".", "\"\""])
    func cleanNameRefuses(raw: String) {
        #expect(WorkspaceNaming.cleanName(raw) == nil)
    }

    @Test("nil in, nil out")
    func cleanNameNil() {
        #expect(WorkspaceNaming.cleanName(nil) == nil)
    }

    @Test("a two hundred character answer is cut at a word boundary")
    func cleanNameLength() throws {
        let sprawl = String(repeating: "invoice ", count: 40)
        let name = try #require(WorkspaceNaming.cleanName(sprawl))
        #expect(name.count <= WorkspaceNaming.nameLimit)
        #expect(!name.hasSuffix(" "))
        #expect(name.hasPrefix("invoice invoice"))
    }

    @Test("a name made only of control characters is refused")
    func cleanNameControlCharacters() {
        #expect(WorkspaceNaming.cleanName("\u{7}\u{1}\u{7F}") == nil)
    }

    @Test(
        "a branch is put through the same slug the mechanical branch uses",
        arguments: [
            ("add-dark-mode-toggle", "add-dark-mode-toggle"),
            ("feature/dark-mode", "dark-mode"),
            ("Add Dark Mode!", "add-dark-mode"),
            ("  spaced out branch  ", "spaced-out-branch"),
        ]
    )
    func cleanBranchNormalises(raw: String, expected: String) {
        #expect(WorkspaceNaming.cleanBranch(raw) == expected)
    }

    @Test(
        "a branch git would refuse, or would read as an option, never gets through",
        arguments: ["", "   ", "--mirror", "..", "HEAD", "-", "@{", "\u{1}"]
    )
    func cleanBranchRefuses(raw: String) {
        let branch = WorkspaceNaming.cleanBranch(raw)
        if let branch {
            // Anything that does survive is only ever a slug, and a slug git will accept.
            #expect(Git.isValidBranchName(branch))
            #expect(!branch.hasPrefix("-"))
        }
    }

    @Test("the repository's own prefix is put back, and the model's is dropped")
    func cleanBranchPrefix() {
        // Never `freek/feature-dark-mode`. The prompt asks for no prefix; when the model adds one
        // anyway, the repository's setting is the one that decides.
        #expect(WorkspaceNaming.cleanBranch("feature/dark-mode", prefix: "freek") == "freek/dark-mode")
        #expect(WorkspaceNaming.cleanBranch("dark-mode", prefix: "freek") == "freek/dark-mode")
        #expect(WorkspaceNaming.cleanBranch("feature/dark-mode") == "dark-mode")
    }

    @Test("a prefix that would make an invalid ref refuses the whole branch")
    func cleanBranchHostilePrefix() {
        #expect(WorkspaceNaming.cleanBranch("dark-mode", prefix: "-x") == nil)
        #expect(WorkspaceNaming.cleanBranch("dark-mode", prefix: "..") == nil)
    }

    @Test("a name with no usable branch is still a usable suggestion")
    func suggestionWithoutBranch() throws {
        let suggestion = try #require(WorkspaceNaming.suggestion(name: "Dark mode", branch: "--"))
        #expect(suggestion.name == "Dark mode")
        #expect(suggestion.branch.isEmpty)
    }

    @Test("no name means no suggestion, whatever the branch said")
    func suggestionWithoutName() {
        #expect(WorkspaceNaming.suggestion(name: "", branch: "dark-mode") == nil)
        #expect(WorkspaceNaming.suggestion(name: nil, branch: "dark-mode") == nil)
    }

    // MARK: - The CLI envelope

    @Test("the structured output is read out of the CLI's json envelope", .tags(.agentProtocol))
    func decodeStructured() throws {
        let json = """
        {"type":"result","subtype":"success","is_error":false,\
        "result":"{\\"name\\":\\"Dark mode toggle\\",\\"branch\\":\\"dark-mode-toggle\\"}",\
        "structured_output":{"name":"Dark mode toggle","branch":"dark-mode-toggle"}}
        """
        let decoded = try #require(WorkspaceNaming.decode(cliOutput: Data(json.utf8)))
        #expect(decoded.name == "Dark mode toggle")
        #expect(decoded.branch == "dark-mode-toggle")
    }

    @Test("an envelope without structured output falls back to the result text", .tags(.agentProtocol))
    func decodeResultText() throws {
        let json = """
        {"type":"result","result":"{\\"name\\":\\"Dark mode\\",\\"branch\\":\\"dark-mode\\"}"}
        """
        let decoded = try #require(WorkspaceNaming.decode(cliOutput: Data(json.utf8)))
        #expect(decoded.name == "Dark mode")
        #expect(decoded.branch == "dark-mode")
    }

    @Test(
        "anything that is not the envelope decodes to nothing rather than to a guess",
        .tags(.agentProtocol),
        arguments: ["", "not json", "[]", "{}", "{\"result\":\"just some prose\"}"]
    )
    func decodeRefuses(raw: String) {
        let decoded = WorkspaceNaming.decode(cliOutput: Data(raw.utf8))
        #expect(decoded == nil || (decoded?.name == nil && decoded?.branch == nil))
    }

    // MARK: - Whether to ask

    @Test("a prompt in a chat workspace, with the setting on and the CLI installed, is named")
    func shouldName() {
        #expect(WorkspaceNaming.shouldName(
            userSuppliedName: nil, prompt: "Add a toggle",
            isChatWorkspace: true, isEnabled: true, isAgentAvailable: true
        ))
    }

    @Test(
        "every reason not to ask",
        arguments: [
            ("the user typed a name", "Billing", "Add a toggle", true, true, true),
            ("a terminal workspace has no task", nil, "Add a toggle", false, true, true),
            ("the setting is off", nil, "Add a toggle", true, false, true),
            ("there is no claude to ask", nil, "Add a toggle", true, true, false),
            ("the prompt is empty", nil, "   \n  ", true, true, true),
        ] as [(String, String?, String, Bool, Bool, Bool)]
    )
    func shouldNotName(
        reason: String,
        name: String?,
        prompt: String,
        isChat: Bool,
        isEnabled: Bool,
        isAvailable: Bool
    ) {
        #expect(!WorkspaceNaming.shouldName(
            userSuppliedName: name, prompt: prompt,
            isChatWorkspace: isChat, isEnabled: isEnabled, isAgentAvailable: isAvailable
        ), "\(reason)")
    }

    // MARK: - Applying

    @Test("the answer only lands on a workspace still wearing the exact placeholder")
    func mayApplyName() {
        #expect(WorkspaceNaming.mayApplyName(current: "Foxglove", placeholder: "Foxglove"))
        // Renamed by hand while the model was thinking.
        #expect(!WorkspaceNaming.mayApplyName(current: "My billing work", placeholder: "Foxglove"))
        // Renamed by hand to another plant. The shape of the name decides nothing.
        #expect(!WorkspaceNaming.mayApplyName(current: "Marigold", placeholder: "Foxglove"))
        #expect(!WorkspaceNaming.mayApplyName(current: "foxglove", placeholder: "Foxglove"))
    }

    @Test("a refusal the user can act on becomes a sentence")
    func notice() throws {
        let text = try #require(WorkspaceNaming.branchNotice(
            name: "Dark mode toggle", branch: "add-a-toggle", refusal: .hasCommits(2)
        ))
        #expect(text.contains("Dark mode toggle"))
        #expect(text.contains("add-a-toggle"))
        #expect(text.contains("2 commits"))
        #expect(text.hasSuffix("."))
    }

    @Test("a refusal that changed nothing the user can see says nothing")
    func silentRefusals() {
        #expect(WorkspaceNaming.branchNotice(
            name: "Dark mode", branch: "dark-mode", refusal: .alreadyNamed
        ) == nil)
        #expect(WorkspaceNaming.branchNotice(
            name: "Dark mode", branch: "dark-mode", refusal: .noValidName
        ) == nil)
    }

    // MARK: - The setting

    @Test("the setting defaults to on and survives a round trip", .tags(.persistence))
    func preference() throws {
        let suite = "bloom.naming.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = WorkspaceNamingPreferences(defaults: defaults)
        #expect(preferences.isEnabled)

        preferences.isEnabled = false
        #expect(!WorkspaceNamingPreferences(defaults: defaults).isEnabled)

        preferences.isEnabled = true
        #expect(WorkspaceNamingPreferences(defaults: defaults).isEnabled)
    }
}

/// What a project's `branchPrefix` means, which used to be written out in three places.
@Suite("Branch prefixes")
struct BranchPrefixTests {
    @Test("a prefix is joined with a slash, and an empty one is no prefix")
    func joining() {
        #expect(Git.prefixed("dark-mode", with: "freek") == "freek/dark-mode")
        #expect(Git.prefixed("dark-mode", with: nil) == "dark-mode")
        #expect(Git.prefixed("dark-mode", with: "") == "dark-mode")
    }

    @Test("the branch a prompt is cut on carries the prefix the same way")
    func branchStemAgrees() {
        #expect(
            Git.branchStem(prompt: "Add dark mode", prefix: "freek")
                == Git.prefixed(Git.slug(from: "Add dark mode"), with: "freek")
        )
    }

    /// The prefix is the owner's own text, and prefixing a valid ref does not always leave one.
    @Test("a prefix that leaves something git will not take is refused rather than used")
    func invalidPrefix() {
        #expect(WorkspaceNaming.prefixedBranch("dark-mode", prefix: "freek") == "freek/dark-mode")
        #expect(WorkspaceNaming.prefixedBranch("dark-mode", prefix: "..") == nil)
        #expect(WorkspaceNaming.prefixedBranch("dark-mode", prefix: "a b") == nil)
    }

    /// The sea a workspace is christened after and a model's suggested rename take the same route,
    /// so a change to what a prefix means cannot land on one of them only.
    @Test("a sea's slug and a suggested branch are prefixed by the same rule")
    func oneRuleForBothNames() throws {
        let suggested = try #require(
            WorkspaceNaming.cleanBranch("dark mode", prefix: "freek")
        )

        #expect(suggested == WorkspaceNaming.prefixedBranch("dark-mode", prefix: "freek"))
    }
}
