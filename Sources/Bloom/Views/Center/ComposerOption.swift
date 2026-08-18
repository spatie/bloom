import BloomCore

/// One entry in a footer picker. The id is what gets written to `Session`, the label is what the
/// user reads, and the two are different on purpose: the CLI wants `opus`, the user wants Opus 5.
struct ComposerOption: Identifiable, Hashable {
    var id: String
    var label: String

    static let models = [
        ComposerOption(id: "opus", label: "Opus 5"),
        ComposerOption(id: "sonnet", label: "Sonnet 5"),
        ComposerOption(id: "haiku", label: "Haiku 4.5"),
    ]

    static let efforts = [
        ComposerOption(id: "low", label: "Low"),
        ComposerOption(id: "medium", label: "Medium"),
        ComposerOption(id: "high", label: "High"),
        ComposerOption(id: "xhigh", label: "Xhigh"),
        ComposerOption(id: "max", label: "Max"),
    ]

    static let permissionModes = PermissionMode.allCases.map {
        ComposerOption(id: $0.rawValue, label: $0.label)
    }

    /// Falls back to a tidied form of the raw value, so a model set in a settings file that Bloom
    /// has never heard of is still shown rather than silently rewritten. Ids such as `opus-5-1m`
    /// and `claude-opus-5[1m]` reach us verbatim and read as "Opus 5 1m" and "Opus 5 (1m)".
    static func label(for id: String, in options: [ComposerOption]) -> String {
        if let match = options.first(where: { $0.id == id }) { return match.label }
        guard !id.isEmpty else { return options.first?.label ?? id }
        return titleCased(id)
    }

    /// `acceptEdits` and `claude-opus-5[1m]` both become something a person can read, without
    /// capitalising the parts that are not words.
    ///
    /// The vendor prefix goes: inside Bloom every model is a Claude model, so the word carries no
    /// information and only costs room in a chip.
    static func titleCased(_ id: String) -> String {
        let parts = id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        // Unless the vendor name is all there is, in which case dropping it leaves nothing to read.
        let named = parts.drop { $0.lowercased() == "claude" }
        return (named.isEmpty ? parts[...] : named)
            .map { part in
                let bracketed = part.replacing("[", with: " (").replacing("]", with: ")")
                guard let first = bracketed.first, first.isLetter else { return bracketed }
                return first.uppercased() + bracketed.dropFirst()
            }
            .joined(separator: " ")
    }
}
