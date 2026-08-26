import Foundation

/// Whether the owner's own Claude Code has already been told about this copy of Bloom.
///
/// One question, asked so that the setup window can stop offering something that is already done.
/// The offer is a command to paste, and a wizard that keeps holding out a command somebody ran
/// last week is a wizard that has not been paying attention.
///
/// **It reads `~/.claude.json`, which holds a live OAuth token, so the parse is pure and takes
/// `Data`.** The tests never open the real file, the same bargain `AgentCatalog.claudeDetails`
/// makes for the account table it reads out of the same place. Nothing here is interested in a
/// credential: the only thing looked at is the `mcpServers` table at the top level, which is the
/// user scope `claude mcp add --scope user` writes into, and the only things compared are a path
/// and two values Bloom itself minted.
///
/// **It never writes.** Bloom does not edit a person's own configuration file, which is the whole
/// reason this feature is a command to copy rather than a write, and reading it to decide whether
/// to offer that command does not change that.
public enum BridgeUserRegistration {
    /// What the user scope says about this copy of Bloom.
    ///
    /// Three cases rather than a `Bool` because "could not tell" is a real answer here and it is
    /// not the same as "no". The file belongs to another program, its shape is not a contract, and
    /// a machine where it cannot be read or parsed is a machine where the honest thing is to offer
    /// the command anyway. Only `registered` is allowed to take the offer away.
    public enum State: String, Sendable, Hashable {
        /// An entry under this Bloom's name, pointing at this Bloom's shim, with this Bloom's
        /// socket and token in it.
        case registered
        /// No entry, or one that names this Bloom and points somewhere else. Those two are one
        /// case on purpose: an entry left behind by a copy of Bloom that has been replaced is a
        /// server Claude Code reports as failed at the start of every session, and the command
        /// that fixes it is the same command somebody who never ran it needs. `claude mcp add`
        /// replaces an entry of the same name, so one paste is the answer to both.
        case notRegistered
        /// The file is not there, or is not JSON any more. Offer the command.
        case unknown
    }

    /// `~/.claude.json`, which is where `--scope user` puts an entry. Named here rather than
    /// spelled out at the call site for the reason `AgentCatalog.claudeAccountPath` is: two
    /// spellings of one path is how a check starts answering about a file nobody writes.
    public static var userConfigPath: String { "\(NSHomeDirectory())/.claude.json" }

    /// Reads the state out of the file's bytes.
    ///
    /// - Parameters:
    ///   - userConfig: the contents of `userConfigPath`, or nil when it could not be read.
    ///   - name: the server name this copy of Bloom registers under. Always
    ///     `BridgeRegistration.ownerServerName` in the app; passed in so a test can name one.
    ///   - attachment: what this copy of Bloom would hand out today, or nil when it has no bridge
    ///     to offer, in which case an entry of the right name is taken at face value.
    public static func state(
        userConfig: Data?,
        serverNamed name: String,
        matching attachment: BridgeAttachment?
    ) -> State {
        guard let userConfig, !userConfig.isEmpty else { return .unknown }
        guard let root = (try? JSONSerialization.jsonObject(with: userConfig)) as? [String: Any] else {
            return .unknown
        }
        // A file with no `mcpServers` table is a Claude Code that has been run and has no user
        // scope servers, which is a straight no rather than a failure to read.
        guard let servers = root["mcpServers"] as? [String: Any] else { return .notRegistered }
        guard let entry = servers[name] as? [String: Any] else { return .notRegistered }
        guard let attachment else { return .registered }
        return matches(entry: entry, attachment: attachment) ? .registered : .notRegistered
    }

    /// Whether an entry is this Bloom's rather than something else wearing its name.
    ///
    /// The shim path, the socket and the token, and deliberately not the role. The role travels in
    /// the attachment for diagnostics only and the server resolves the real one from the token, so
    /// an entry that disagrees about it still works and re-offering the command over it would be
    /// the check inventing a problem. See `BridgeProtocol.roleVariable`.
    ///
    /// The token is compared because Regenerate exists. It revokes the old one the moment it is
    /// pressed, and the pane that offers it says to run the new command afterwards; until somebody
    /// does, the entry in this file is a server that will be refused at the handshake, which is
    /// exactly the state this window should be offering to fix.
    private static func matches(entry: [String: Any], attachment: BridgeAttachment) -> Bool {
        guard entry["command"] as? String == attachment.shimPath else { return false }
        let environment = entry["env"] as? [String: Any]
        for variable in [BridgeProtocol.socketVariable, BridgeProtocol.tokenVariable] {
            guard environment?[variable] as? String == attachment.environment[variable] else {
                return false
            }
        }
        return true
    }
}
