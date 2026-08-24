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
        // "Extra high", not "Xhigh": the same value already reads that way in
        // `CodexModelCatalog`, whose head says why, and one id spelled two ways in one window is
        // two settings as far as anybody reading them is concerned.
        ComposerOption(id: "xhigh", label: "Extra high"),
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

    /// `ModelLabel.readable` in the core, where it can be tested. See its head for why it moved.
    static func titleCased(_ id: String) -> String { ModelLabel.readable(id) }
}
