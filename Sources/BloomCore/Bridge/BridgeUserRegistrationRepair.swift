import Foundation

/// Re-points the owner's durable user scope entry when Bloom's bundle has moved, and refuses to
/// touch anything else in the file it finds it in.
///
/// ## The bug this exists for
///
/// `claude mcp add --scope user` writes an absolute path into `~/.claude.json`, once, and nothing
/// ever looks at it again:
///
///     "command": "/Users/freek/Applications/Bloom.app/Contents/MacOS/bloom-bridge"
///
/// The owner then dragged Bloom from `~/Applications` to `/Applications`. Every agent started from
/// his own terminal failed from that moment on, saying the bridge was down and naming a path that
/// no longer exists, and it stayed broken until somebody edited the file by hand. Nothing else was
/// wrong: `BridgeRegistration.shimPath` derives the shim from the running executable, so every
/// per-session registration Bloom writes for a workspace agent was correct throughout. The fault
/// is only in the one entry that is written once and then never re-derived.
///
/// ## What counts as ours, and stale
///
/// Re-pointing an entry Bloom did not write, or one deliberately aimed at another copy of Bloom,
/// would be a worse bug than the one being fixed, so the test is deliberately narrow. All of these
/// have to hold:
///
/// - The entry is under **this copy's own** `BridgeRegistration.ownerServerName`. That name is
///   derived from `Store.databaseDirectoryName`, so the release copy only ever looks at `bloom`,
///   the dev copy at `bloom-dev` and the subagents copy at `bloom-subagents`. The three identities
///   in `Tools/guard.sh` therefore cannot fight over one entry: they are not looking at the same
///   one.
/// - Its `BLOOM_BRIDGE_SOCKET` and `BLOOM_BRIDGE_TOKEN` are **exactly what this instance would
///   hand out today**. The socket is derived from the database path through
///   `TmuxSessions.fingerprint`, which is the one rule that says which copy of Bloom a process is,
///   and the token is a random value minted beside that database. Nothing but this instance can
///   produce that pair, so the pair is the proof of authorship. The role is not compared, for the
///   reason `BridgeUserRegistration.matches` gives.
/// - Its `command` names a file called `bloom-bridge`. Belt and braces over the pair above, and it
///   is what stops a repair landing on a wrapper script somebody pointed the entry at.
/// - **That path does not exist.** This is what "stale" means, and it is the condition that keeps
///   a deliberate cross-wire working: the shim is a relay that takes its socket and token from the
///   environment, so a Bloom Dev shim driving the release copy's socket is a working arrangement,
///   and an entry whose binary is still there is left alone whoever put it there.
///
/// Everything that is not all four of those is left exactly as it was.
///
/// ## Why the token is not refreshed
///
/// A move cannot make the token stale. It lives beside the database as `BridgeOwnerToken` and
/// survives relaunches on purpose, so the entry's copy is still right after the bundle moves. A
/// token that disagrees means one of two things, and neither is this function's business: the
/// entry was not minted by this instance, which is the identity test above refusing it, or the
/// owner pressed Regenerate and has not re-pasted, which is a revocation to leave standing rather
/// than to quietly undo. `BridgeUserRegistration.state` already answers `notRegistered` for both,
/// so the welcome step and the Command Line pane go on offering the command that fixes them, with
/// one paste. This repair changes one string, and it is the one the move broke.
///
/// ## Why this may write a file `BridgeUserRegistration` says Bloom does not write
///
/// That file's rule is that Bloom does not compose a person's configuration for them, which is why
/// the feature is a command to copy rather than a write, and it still stands. Correcting a path
/// inside an entry Bloom itself minted, which it can prove it minted, and which currently names
/// nothing at all, is repairing Bloom's own record rather than editing somebody's setup.
public enum BridgeUserRegistrationRepair {
    /// Why nothing was written. Every one of these is an ordinary outcome, and the first is by far
    /// the most common: the entry is already right.
    public enum Reason: String, Sendable, Hashable {
        /// The file is not there, or came back empty.
        case unreadable
        /// It is not JSON any more, or its root is not an object. Another program's file, whose
        /// shape is not a contract.
        case malformed
        /// No `mcpServers` table, or nothing in it under this copy's name.
        case absent
        /// An entry under the name that this instance cannot prove it wrote.
        case notOurs
        /// Already pointing at this bundle's shim. The common case.
        case alreadyCorrect
        /// Pointing somewhere else, at a `bloom-bridge` that is still there. Not stale, so not
        /// this function's business.
        case shimStillThere
    }

    /// What reading the file decided.
    public enum Repair: Sendable, Equatable {
        case leaveAlone(Reason)
        /// The whole file, re-serialised with one string changed, ready to go back over it.
        case rewrite(Data, from: String, to: String)
    }

    /// What `repairIfStale` did, for the log.
    public enum Outcome: Sendable, Equatable {
        case unchanged(Reason)
        case repaired(from: String, to: String)
        case couldNotWrite(String)
    }

    /// The rule, over bytes, so a test never opens a real home directory.
    ///
    /// - Parameters:
    ///   - userConfig: the contents of `BridgeUserRegistration.userConfigPath`, or nil when it
    ///     could not be read.
    ///   - name: the server name this copy of Bloom registers under. Always
    ///     `BridgeRegistration.ownerServerName` in the app; passed in so a test can name one.
    ///   - attachment: what this copy of Bloom would hand out today.
    ///   - shimExists: whether a path names an executable. A parameter because the decision has to
    ///     be answerable without a file system, and because the fixtures name paths that must not
    ///     be created.
    public static func decide(
        userConfig: Data?,
        serverNamed name: String,
        matching attachment: BridgeAttachment,
        shimExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Repair {
        guard let userConfig, !userConfig.isEmpty else { return .leaveAlone(.unreadable) }
        guard var root = (try? JSONSerialization.jsonObject(with: userConfig)) as? [String: Any] else {
            return .leaveAlone(.malformed)
        }
        guard var servers = root["mcpServers"] as? [String: Any] else { return .leaveAlone(.absent) }
        guard var entry = servers[name] as? [String: Any] else { return .leaveAlone(.absent) }
        guard let command = entry["command"] as? String,
              (command as NSString).lastPathComponent == shimName else {
            return .leaveAlone(.notOurs)
        }
        guard isOurs(entry: entry, attachment: attachment) else { return .leaveAlone(.notOurs) }
        guard command != attachment.shimPath else { return .leaveAlone(.alreadyCorrect) }
        guard !shimExists(command) else { return .leaveAlone(.shimStillThere) }

        entry["command"] = attachment.shimPath
        servers[name] = entry
        root["mcpServers"] = servers
        // Pretty printed and with slashes left alone, because this is somebody else's file and the
        // shape it is already in is the shape Claude Code writes. The key order cannot be kept:
        // JSON objects come out of `JSONSerialization` unordered, and the alternative is a
        // byte-level edit of a file whose format is not a contract.
        guard let rewritten = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ) else {
            return .leaveAlone(.malformed)
        }
        return .rewrite(rewritten, from: command, to: attachment.shimPath)
    }

    /// Reads the file, decides, and writes only when there is a real difference.
    ///
    /// Nothing here throws. Every way this can fail, an absent file, one being rewritten by Claude
    /// Code at this instant, one holding JSON this app did not expect, a directory that cannot be
    /// written, is "leave it alone and carry on": the coupling stays broken until somebody pastes
    /// the command, which is where it was before this function existed.
    ///
    /// The read, the decision and the write are one uninterrupted stretch, because Claude Code
    /// does its own read-modify-write on this file with no lock either and the only thing that can
    /// be done about the race is to make the window as short as possible. The window is opened at
    /// all only on the launch after a move.
    ///
    /// `shimExists` is a parameter for the same reason it is one on `decide`: a test that drove
    /// this through the real file system would be a test whose answer depended on what happens to
    /// be installed on the machine running it.
    @discardableResult
    public static func repairIfStale(
        path: String = BridgeUserRegistration.userConfigPath,
        serverNamed name: String,
        matching attachment: BridgeAttachment,
        shimExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Outcome {
        let contents = FileManager.default.contents(atPath: path)
        let repair = decide(
            userConfig: contents,
            serverNamed: name,
            matching: attachment,
            shimExists: shimExists
        )
        switch repair {
        case .leaveAlone(let reason):
            return .unchanged(reason)
        case .rewrite(let data, let from, let to):
            do {
                try write(data, to: path)
                return .repaired(from: from, to: to)
            } catch {
                return .couldNotWrite(error.readableMessage)
            }
        }
    }

    /// The basename `BridgeRegistration.shimPath` looks for, and therefore the only one an entry
    /// this instance wrote can carry.
    static let shimName = "bloom-bridge"

    /// Whether the socket and the token in an entry are the pair only this instance can mint.
    private static func isOurs(entry: [String: Any], attachment: BridgeAttachment) -> Bool {
        let environment = entry["env"] as? [String: Any]
        for variable in [BridgeProtocol.socketVariable, BridgeProtocol.tokenVariable] {
            guard environment?[variable] as? String == attachment.environment[variable] else {
                return false
            }
        }
        return true
    }

    /// Atomically, and at the mode it found.
    ///
    /// `.atomic` writes a neighbouring temporary file and renames it over this one, so a crash or
    /// a full disk halfway through leaves the owner's configuration as it was rather than
    /// truncated. The mode is read first and put back afterwards, the same way
    /// `BridgeRegistration.writeClaudeConfig` chmods after writing: this file holds a live OAuth
    /// token, and a repair that left it world readable would be a worse trade than the bug.
    private static func write(_ data: Data, to path: String) throws {
        let existing = try? FileManager.default.attributesOfItem(atPath: path)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let mode = existing?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }
}
