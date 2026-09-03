import Foundation

/// One run script while it is being edited.
///
/// The TOML table name (`[scripts.run.dev]`) is not a good identity for a row in a list: it does
/// not exist yet for a script that has just been added, and deriving it from the name as the name
/// is typed would change it under the list, which is enough to make a text field lose focus
/// mid-word. So a row has an identity of its own and the table name is settled on the way to disk.
public struct DraftRunScript: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// The table name this script already has in the file. Empty for one never saved.
    public var key: String
    public var name: String
    public var command: String

    public init(id: UUID = UUID(), key: String = "", name: String = "", command: String = "") {
        self.id = id
        self.key = key
        self.name = name
        self.command = command
    }
}

/// The editable copy of one repository's settings, and the difference between it and the files.
///
/// A plain value with no view in it, so what a Save is about to write can be asserted in a test
/// rather than judged from a screenshot. `RepoSettingsModel` holds one of these and binds the
/// window's fields straight to it.
///
/// Everything is compared trimmed. TOML's multi-line string forms keep the newline before their
/// closing delimiter, so a script written and read back is one newline longer than it went in, and
/// an untrimmed comparison would leave the window claiming unsaved changes forever.
public struct RepoSettingsDraft: Sendable, Hashable {
    public var setupScript = ""
    public var archiveScript = ""
    /// One glob per line, as typed.
    public var filesToCopyText = ""
    public var runScripts: [DraftRunScript] = []
    public var runMode = "nonconcurrent"
    public var branchPrefix = ""
    public var deleteBranchOnArchive = false
    /// What this project adds to the two turns Bloom composes about landing a branch. Empty for
    /// most projects, which is the answer that sends a turn with nothing attached to it.
    public var mergeInstructions = ""
    public var conflictInstructions = ""

    public init() {}

    public init(_ settings: RepoSettings) {
        setupScript = settings.setupScript ?? ""
        archiveScript = settings.archiveScript ?? ""
        filesToCopyText = settings.filesToCopy.joined(separator: "\n")
        runScripts = settings.runScripts.map {
            DraftRunScript(key: $0.id, name: $0.name, command: $0.command)
        }
        runMode = settings.runMode
        branchPrefix = settings.branchPrefix ?? ""
        deleteBranchOnArchive = settings.deleteBranchOnArchive
        mergeInstructions = settings.mergeInstructions ?? ""
        conflictInstructions = settings.conflictInstructions ?? ""
    }

    /// The patterns, one per line. A blank line is not a pattern, and an empty field means "copy
    /// nothing", which is a different answer from "say nothing" and is written as such.
    public var globs: [String] {
        filesToCopyText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The run scripts with a table name worked out for the ones that do not have one yet, and
    /// with the empty rows dropped: a row with no command is a row somebody started and abandoned.
    public var resolvedRunScripts: [RunScript] {
        var used = Set(runScripts.map(\.key).filter { !$0.isEmpty })
        return runScripts.compactMap { script in
            let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            var key = script.key
            if key.isEmpty {
                key = Self.uniqueKey(from: script.name, avoiding: used)
                used.insert(key)
            }
            let name = script.name.trimmingCharacters(in: .whitespaces)
            return RunScript(id: key, name: name.isEmpty ? key.capitalizedFirst : name, command: command)
        }
    }

    /// A table name taken from what the user called the script, so `[scripts.run.dev]` reads like
    /// the thing it runs rather than like a serial number.
    public static func uniqueKey(from name: String, avoiding used: Set<String>) -> String {
        let slug = name
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.isEmpty || result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let base = slug.isEmpty ? "run" : slug
        guard used.contains(base) else { return base }
        var index = 2
        while used.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// Only what actually changed, so pressing Save cannot add keys to a shared file that the user
    /// never touched merely because they opened the window and looked at it.
    public func edits(comparedTo settings: RepoSettings) -> [SettingsEdit] {
        var edits: [SettingsEdit] = []

        let setup = setupScript.trimmed
        if setup != (settings.setupScript ?? "").trimmed {
            edits.append(.setupScript(setup))
        }
        let archive = archiveScript.trimmed
        if archive != (settings.archiveScript ?? "").trimmed {
            edits.append(.archiveScript(archive))
        }
        if globs != settings.filesToCopy {
            edits.append(.filesToCopy(globs))
        }
        if resolvedRunScripts != settings.runScripts {
            edits.append(.runScripts(resolvedRunScripts))
        }
        if runMode != settings.runMode {
            edits.append(.runMode(runMode))
        }
        let prefix = branchPrefix.trimmingCharacters(in: .whitespaces)
        if prefix != (settings.branchPrefix ?? "") {
            edits.append(.branchPrefix(prefix))
        }
        if deleteBranchOnArchive != settings.deleteBranchOnArchive {
            edits.append(.deleteBranchOnArchive(deleteBranchOnArchive))
        }
        let merge = mergeInstructions.trimmed
        if merge != (settings.mergeInstructions ?? "").trimmed {
            edits.append(.mergeInstructions(merge))
        }
        let conflicts = conflictInstructions.trimmed
        if conflicts != (settings.conflictInstructions ?? "").trimmed {
            edits.append(.conflictInstructions(conflicts))
        }
        return edits
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
