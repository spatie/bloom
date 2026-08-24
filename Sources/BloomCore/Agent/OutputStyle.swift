import Foundation

/// One entry in Claude Code's output style list: how the assistant writes, as opposed to what it
/// is allowed to do.
///
/// The name is both the value the CLI's `outputStyle` setting takes and the words the user reads,
/// which is why there is no separate id and label here the way there is on `ComposerOption`. A
/// model has two names, `opus` for the CLI and Opus 5 for the person; an output style has one,
/// because the built in four are called Proactive, Concise, Explanatory and Learning in the
/// binary and a custom one is called whatever its own file says.
public struct OutputStyle: Identifiable, Hashable, Sendable {
    public var name: String
    /// One line about what the style does. The CLI's own words for the built in four, read out of
    /// the installed binary rather than written from memory, and the file's `description`
    /// frontmatter for the rest.
    public var detail: String
    /// True for the four the CLI compiles in. Only used to keep them above whatever the user has
    /// written, because those four are the ones almost every reader is looking for.
    public var isBuiltIn: Bool

    public var id: String { name }

    public init(name: String, detail: String, isBuiltIn: Bool = false) {
        self.name = name
        self.detail = detail
        self.isBuiltIn = isBuiltIn
    }

    /// What the CLI calls "no style", and what Bloom stores when the picker is left alone.
    ///
    /// The binary's own table of styles has this as a key mapping to nothing, so it is a real
    /// value rather than an invention here. Bloom still sends no setting at all for it rather than
    /// sending the word: an absent key cannot override a style set for the repository in a
    /// `.claude/settings.json`, and stating the default explicitly would.
    public static let defaultName = "default"

    /// The row for "leave it alone". First in the list, because it is what every session is until
    /// somebody says otherwise.
    ///
    /// Its sentence is ours and not the CLI's. The CLI has none, since inside the binary the
    /// default is the absence of an entry rather than an entry describing itself.
    public static let unstyled = OutputStyle(
        name: defaultName,
        detail: "Claude writes the way it does with no style set",
        isBuiltIn: true
    )

    /// The four styles compiled into the CLI, in the order the binary lists them, with the
    /// descriptions it carries for each. They cannot be discovered from disk, only asserted, in
    /// exactly the way `SlashCommandIndex.builtIns` cannot: they live inside the executable.
    ///
    /// Read out of 2.1.238. Anthropic announced Concise on 20 August 2026 and the other three were
    /// already there. If a release adds a fifth it will be missing here until somebody looks
    /// again, which is the same bargain the slash command list makes and for the same reason.
    public static let builtIns: [OutputStyle] = [
        unstyled,
        OutputStyle(
            name: "Proactive",
            detail: "Claude executes immediately, minimizes interruptions, and prefers action over planning",
            isBuiltIn: true
        ),
        OutputStyle(
            name: "Concise",
            detail: "Claude responds tersely, leading with results and skipping preamble and narration",
            isBuiltIn: true
        ),
        OutputStyle(
            name: "Explanatory",
            detail: "Claude explains its implementation choices and codebase patterns",
            isBuiltIn: true
        ),
        OutputStyle(
            name: "Learning",
            detail: "Claude pauses and asks you to write small pieces of code for hands-on practice",
            isBuiltIn: true
        ),
    ]

    /// Whether a stored value is worth sending to the CLI at all.
    ///
    /// Empty is a session that has never been asked, and `default` is one that was asked and said
    /// no. Both mean the same thing on the wire: send nothing.
    public static func isDefault(_ name: String?) -> Bool {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == defaultName
    }
}
