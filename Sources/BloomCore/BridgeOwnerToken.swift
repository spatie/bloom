import Foundation

/// The one bridge token that is allowed to survive a relaunch, and the reasoning that lets it.
///
/// ## Why this contradicts nothing in `BridgeRegistry`
///
/// `BridgeRegistry` holds every token in memory and says why in as many words: a token written to
/// disk would be a token that outlived the process it identified. That is exactly right for a
/// session token. A session token is minted for a process Bloom is about to launch, the argv
/// carrying it is rebuilt at every launch, and a session resumed a week later gets a fresh one for
/// free, so persistence would buy nothing and would leave a usable token lying about for a process
/// that no longer exists.
///
/// The standalone token identifies no process Bloom starts. It identifies a client configuration
/// that Bloom hands to a person once and then never sees again: it is pasted into the user's own
/// MCP configuration, where it sits until they take it out. If it were minted per launch, that
/// pasted configuration would be dead every morning, and a coupling that breaks every time the app
/// restarts is not a coupling. So the lifetime is deliberately the opposite: as long as the
/// arrangement it describes, ended by the owner regenerating it rather than by a quit.
///
/// ## Why a file beside the database rather than the Keychain
///
/// Three reasons, and the first is the one that settles it. The token's only consumer is a plain
/// text `mcpServers` entry in the user's own configuration, so at rest it already exists in a file
/// readable by anything running as the user. Keeping Bloom's copy in the Keychain would protect
/// one end of a pair whose other end cannot be protected, which is theatre.
///
/// Second, the boundary the Keychain defends is a different user on the machine, and that boundary
/// is already held here: the socket the token unlocks sits in the per-user Darwin temporary
/// directory, which is 0700, and so does the database this file sits beside. Anything that can
/// read this file can read the database it is next to, and the database is the thing worth having.
///
/// Third, a Keychain item is access-controlled by signing identity, and Bloom is re-signed ad hoc
/// on every development build, so every rebuild would raise an authorisation dialogue over a value
/// that `BridgeProtocol` already documents as not a secret.
///
/// The file is 0600 in a 0700 directory all the same, because "not a secret" is not the same as
/// "print it in the newspaper", and because the mode is what makes the sentence above true.
public struct BridgeOwnerToken: Sendable {
    /// Where it lives: beside the database, so the separation between Bloom and Bloom Dev that
    /// every other piece of per-instance state already has costs nothing here. Two copies of the
    /// app must not share one owner token, for the same reason they must not share one socket.
    public let path: String

    private let makeToken: @Sendable () -> String

    public init(
        path: String,
        makeToken: @escaping @Sendable () -> String = BridgeRegistry.randomToken
    ) {
        self.path = path
        self.makeToken = makeToken
    }

    /// The token file beside `databasePath`.
    public static func beside(databasePath: String) -> BridgeOwnerToken {
        let directory = (databasePath as NSString).deletingLastPathComponent
        return BridgeOwnerToken(
            path: (directory as NSString).appendingPathComponent("bridge-owner-token")
        )
    }

    /// The stored token, minting and writing one the first time anybody asks.
    ///
    /// Whitespace is trimmed on the way in because the file is plain text in a directory a person
    /// can open, and a trailing newline from an editor must not turn into a token that no longer
    /// matches what was pasted. An empty or unreadable file is treated as no file at all: there is
    /// nothing to lose by minting again, and the alternative is a Bloom that cannot be coupled to
    /// anything until somebody deletes a file they were never told about.
    @discardableResult
    public func load() throws -> String {
        if let stored = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return try regenerate()
    }

    /// A new token, replacing whatever was there.
    ///
    /// This is revocation. The old token is not written anywhere else by Bloom, so overwriting the
    /// file is the whole of taking it back, and the copy in the user's own configuration stops
    /// working at the next handshake. The UI that offers this has to say so, because a person who
    /// regenerates without repasting is a person whose terminal quietly stopped working.
    @discardableResult
    public func regenerate() throws -> String {
        let token = makeToken()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Written and then chmodded rather than created with attributes, because `createFile`
        // leaves an existing file's mode alone and this path is rewritten every regeneration.
        try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return token
    }
}
