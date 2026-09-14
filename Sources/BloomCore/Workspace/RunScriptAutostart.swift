import Foundation

/// The commands the owner has said may start on their own when a project's workspace opens.
///
/// **`autostart = true` in a file is a request, not a permission.** The file is committed, so the
/// line can arrive by `git pull` from anyone with push access, and a command that starts itself
/// the moment a workspace opens is a command nobody read. So nothing autostarts until the owner
/// has approved the exact text of each command, and a command that changes by so much as a flag
/// is asked about again.
///
/// **Every command approved for a script is kept, not only the last.** One project has many
/// workspaces on many branches, and a branch that changes `yarn dev` to `pnpm dev` is ordinary.
/// Keeping only the last approval would ask about one, then the other, every time the owner
/// switched between two workspaces, and a question asked that often is a question answered
/// without reading. What is approved stays approved; `Self.historyLimit` keeps the list short.
///
/// Stored as the commands themselves rather than a hash of them, because the question has to be
/// able to say what changed: "was `yarn dev`, is now `yarn dev --host`" is a question somebody can
/// answer, and "the fingerprint changed" is not.
public struct RunScriptAutostartApproval: Codable, Sendable, Hashable {
    /// For each run script id, the commands approved for it, oldest first. For a script that is a
    /// file, the command is the file's text, so an edit to the file is a change like any other.
    public var commands: [String: [String]]

    public init(commands: [String: [String]] = [:]) {
        self.commands = commands
    }

    /// How many commands are remembered per script. Enough for a handful of live branches; the
    /// oldest goes first.
    static let historyLimit = 8

    /// The settings row, one per project.
    public static func key(repoID: RepoID) -> String {
        "runScripts.autostart.approved.\(repoID.rawValue)"
    }

    /// Whether this exact command has been approved for this script.
    public func approves(_ script: RunScript) -> Bool {
        commands[script.id]?.contains(script.command) == true
    }

    /// This approval with every script given added to it, which is what pressing Allow writes.
    public func approving(_ scripts: [RunScript]) -> RunScriptAutostartApproval {
        var next = self
        for script in scripts {
            var history = next.commands[script.id, default: []]
            history.removeAll { $0 == script.command }
            history.append(script.command)
            next.commands[script.id] = Array(history.suffix(Self.historyLimit))
        }
        return next
    }

    /// Nil for a project that has never approved anything. A row that will not decode reads as
    /// nil too, which asks again: the safe direction for a permission.
    public static func load(repoID: RepoID, from store: Store) async -> RunScriptAutostartApproval? {
        guard let raw = try? await store.setting(key(repoID: repoID)),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(RunScriptAutostartApproval.self, from: data)
    }

    public func save(repoID: RepoID, to store: Store) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        try await store.setSetting(Self.key(repoID: repoID), String(decoding: data, as: UTF8.self))
    }
}

/// What opening a workspace does about the run scripts that ask to start on their own.
public enum RunScriptAutostart: Sendable, Hashable {
    /// No script asks to autostart.
    case nothing
    /// Every script that asks has been approved with exactly this command. Run these, in order.
    case run([RunScript])
    /// Ask first. `scripts` is every script that asks, which is what an approval covers.
    /// `changes` is empty for a project that has never approved anything, and otherwise names the
    /// scripts whose command is not one that was approved, with the one approved last.
    case ask(scripts: [RunScript], changes: [Change])

    public struct Change: Sendable, Hashable {
        public var script: RunScript
        /// The command approved most recently for this script, or nil for a script that has never
        /// been approved at all.
        public var approved: String?

        public init(script: RunScript, approved: String?) {
            self.script = script
            self.approved = approved
        }
    }

    /// The decision, given the project's resolved run scripts and whatever it has approved.
    ///
    /// A script with nothing to run (a file that is missing) is not a candidate, so it neither
    /// runs nor makes the owner approve an empty command.
    ///
    /// A script that stopped asking, or went away, needs no new approval. Removing a command from
    /// the set cannot make anything run that the owner did not approve, so it is not a change
    /// worth a question.
    public static func decide(
        scripts: [RunScript], approval: RunScriptAutostartApproval?
    ) -> RunScriptAutostart {
        let candidates = scripts.filter {
            $0.autostart && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { return .nothing }

        guard let approval else { return .ask(scripts: candidates, changes: []) }
        let unapproved = candidates.filter { !approval.approves($0) }
        guard !unapproved.isEmpty else { return .run(candidates) }
        return .ask(
            scripts: candidates,
            changes: unapproved.map { Change(script: $0, approved: approval.commands[$0.id]?.last) }
        )
    }
}

extension RunScriptAutostart {
    /// Whether now is the moment to act on autostart for a workspace that has just been shown.
    ///
    /// Not while its setup script is running, and not before a setup script that is about to run
    /// has started: a dev server started ahead of `npm ci` fails on a missing module, and the
    /// strip that says so would be the first thing a new workspace shows. The run that finishes
    /// setup successfully asks again. A setup that failed does not hold autostart back for good:
    /// the next time the workspace is shown, the scripts start, and whatever they print about a
    /// missing dependency is in a terminal somebody can read.
    ///
    /// `.pending` with a setup script is a workspace whose setup has not run yet, which is the
    /// first moments of a new one. It is also, rarely, a workspace made before its project had a
    /// setup script at all; that one does not autostart until its setup is run once, which errs
    /// towards starting nothing.
    public static func isTimely(isRunningSetup: Bool, setupState: SetupState, hasSetupScript: Bool) -> Bool {
        if isRunningSetup { return false }
        switch setupState {
        case .running: return false
        case .pending: return !hasSetupScript
        case .succeeded, .failed, .skipped: return true
        }
    }
}
