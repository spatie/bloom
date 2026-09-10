import Foundation

/// NUL separators keep spaces, non-ASCII names and newlines intact. Merge conflicts can list a
/// tracked path more than once, but a picker must offer each file only once.
public enum WorkspaceFileSearch {
    public static func paths(in directory: String) async throws -> [String] {
        let result = try await Shell.run(
            "git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd: directory, timeout: .seconds(10)
        )
        return Array(Set(result.stdout.split(separator: "\0").map(String.init))).sorted()
    }
}
