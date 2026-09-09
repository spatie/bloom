import Foundation

/// The address a browser pane opens on when a workspace is asked for one, and the two ways a
/// project can say what that address is.
///
/// `http://localhost:$BLOOM_PORT` was the only answer there was, and it is the right answer only
/// for a project whose dev server is the thing listening on that port. A Herd or Valet site
/// answers on `https://<site>.test` and on nothing else, a compose stack publishes whatever its
/// file says, and a project whose front door is `/admin` or a signed sign-in link wants a path as
/// well as a host. In all three the `+` opened a browser on a socket nothing was listening to.
///
/// There are two sources because there are two different questions. `browser.url` in the settings
/// file is what a project states once for every workspace, and it is expanded with the same
/// variables the scripts are handed, so `http://localhost:$BLOOM_PORT/admin` is a line somebody
/// can commit. The file at `$BLOOM_URL_FILE` is for an address only the setup script can know: a
/// site named after a slug it computed, a tunnel that printed its hostname, a sign-in link
/// carrying a token minted while the database was being seeded. The file wins, because it is
/// written by the thing that has just run.
///
/// Nothing here checks an address beyond it being one non-empty line. A typo that reaches the
/// address bar says where it came from; one quietly swapped for `localhost` looks like Bloom
/// ignoring the file the script just wrote.
public enum WorkspaceBrowserURL {
    /// Where a script writes the address, relative to the worktree.
    ///
    /// Inside `WorktreeScratch.generated`, so git cannot see it. The address is a fact about one
    /// worktree on one machine, and a `.test` hostname arriving in somebody's pull request is
    /// exactly the noise that folder exists to stop.
    public static let file = "\(WorktreeScratch.generated)/url"

    /// The absolute path handed to every script as `$BLOOM_URL_FILE`.
    public static func path(inWorktree worktree: String) -> String {
        (worktree as NSString).appendingPathComponent(file)
    }

    /// The address to open, from whichever source states one.
    ///
    /// Empty when nothing does and no port has been allocated either, which is what a browser
    /// pane reads as "open on nothing" and is what it did before any of this existed.
    ///
    /// - Parameter written: the contents of the file the scripts write, or nil when there is none.
    /// - Parameter stated: `browser.url` as the settings file states it, before expansion.
    /// - Parameter environment: the variables scripts are handed, which is what `stated` expands
    ///   against.
    /// - Parameter port: the workspace's own port, or 0 while it holds none.
    /// - Returns: an address with a scheme, or an empty string.
    public static func resolve(
        written: String?, stated: String?, environment: [String: String], port: Int
    ) -> String {
        if let address = address(written) { return address }
        if let address = address(stated.map { expand($0, with: environment) }) { return address }
        return port > 0 ? "http://localhost:\(port)" : ""
    }

    /// The same answer, having read the file the scripts write.
    ///
    /// - Parameter worktree: the workspace's own folder.
    /// - Parameter settings: the project's settings, for `browser.url`.
    /// - Parameter environment: the variables scripts are handed.
    /// - Parameter port: the workspace's own port, or 0 while it holds none.
    /// - Returns: an address with a scheme, or an empty string.
    public static func read(
        worktree: String, settings: RepoSettings, environment: [String: String], port: Int
    ) -> String {
        let written = try? String(contentsOfFile: path(inWorktree: worktree), encoding: .utf8)
        return resolve(
            written: written, stated: settings.browserURL, environment: environment, port: port
        )
    }

    /// One line, trimmed, carrying a scheme. Nil for anything that states nothing.
    ///
    /// The first non-empty line rather than the whole file, because `echo` is how a script writes
    /// this and a trailing newline is what `echo` leaves. A missing scheme is filled in rather
    /// than refused: `myapp.test` is what a person writes when the point they are making is the
    /// hostname, and `http://` in front of it is what every address bar does with it anyway.
    static func address(_ raw: String?) -> String? {
        guard let line = raw?
            .components(separatedBy: .newlines)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.contains("://") ? line : "http://" + line
    }

    /// `$NAME` and `${NAME}` replaced from the table the scripts are handed.
    ///
    /// A name nothing sets is left exactly as it was typed rather than blanked. `$BLOOM_PROT` is
    /// a typo, and an address bar showing it is a person's answer in one glance; the same typo
    /// blanked produces `http://localhost:` and a question about Bloom.
    static func expand(_ template: String, with environment: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)

        while let dollar = rest.firstIndex(of: "$") {
            result += rest[rest.startIndex..<dollar]

            var cursor = rest.index(after: dollar)
            let braced = cursor < rest.endIndex && rest[cursor] == "{"
            if braced { cursor = rest.index(after: cursor) }

            var name = ""
            while cursor < rest.endIndex, isNameCharacter(rest[cursor]) {
                name.append(rest[cursor])
                cursor = rest.index(after: cursor)
            }

            let closed = !braced || (cursor < rest.endIndex && rest[cursor] == "}")
            if braced, closed { cursor = rest.index(after: cursor) }

            if !name.isEmpty, closed, let value = environment[name] {
                result += value
            } else {
                result += rest[dollar..<cursor]
            }
            rest = rest[cursor...]
        }

        return result + rest
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
    }
}
