import Foundation

/// Filesystem containment, not just a lexical prefix: a symlink must not widen a worktree's access.
public enum ContainedPath {
    public static func resolve(_ url: URL, inside root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }

    static func relative(_ path: String, inside root: String, forWriting: Bool = false) -> URL? {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath,
              !path.split(separator: "/").contains("..") else { return nil }
        let base = URL(filePath: root, directoryHint: .isDirectory).resolvingSymlinksInPath()
        if forWriting {
            // Refuse even an in-root destination symlink. Copying must never overwrite a second
            // path the branch author chose in place of the configured destination.
            var component = base
            for part in path.split(separator: "/") {
                component.append(path: String(part))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                    return nil
                }
            }
        }
        return resolve(base.appending(path: path), inside: base)
    }
}
