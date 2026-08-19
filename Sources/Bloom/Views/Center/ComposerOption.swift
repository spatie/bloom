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

    /// The built-in list plus any id the app is in, or has been in, that is not on it.
    ///
    /// Model and effort ids are an open set. A repository's settings file, `~/.conductor` or the
    /// Models screen can pin one Bloom has no name for, and `opus-5-1m` in a settings file is a
    /// real example: the chip read "Opus 5 1m" and the agent ran on it, while the menu offered
    /// three models, none of them the one in force. Picking any of the three was then a one-way
    /// door, because the id that was configured had disappeared from the only control that could
    /// have put it back.
    ///
    /// So whatever the app has been set to is on the list, and it stays on the list. It goes after
    /// the named ones, because those are the ones almost every reader wants.
    static func adding(_ extras: [String], to options: [ComposerOption]) -> [ComposerOption] {
        var known = Set(options.map(\.id))
        var result = options
        for id in extras {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, known.insert(trimmed).inserted else { continue }
            result.append(ComposerOption(id: trimmed, label: label(for: trimmed, in: options)))
        }
        return result
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
