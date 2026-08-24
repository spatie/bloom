import BloomCore

/// The changed files of one directory.
///
/// Grouping and sorting used to happen in `ChangedFileList.body`, which SwiftUI runs far more
/// often than the file list actually changes, and a running agent rewrites that list every few
/// seconds. Built here instead, once per change.
struct ChangedFileGroup: Identifiable {
    var directory: String
    var files: [ChangedFile]

    var id: String { directory }

    /// The directory said once, dimmed, with its files under it in name order.
    ///
    /// The names are taken once and sorted beside their files rather than read inside the
    /// comparator. `ChangedFile.filename` bridges the path to `NSString` on every access, and a
    /// comparator reads it O(n log n) times, on a list a running agent rewrites every six seconds.
    static func build(from files: [ChangedFile]) -> [ChangedFileGroup] {
        Dictionary(grouping: files, by: \.directory)
            .map { directory, files in
                let named = files.map { (name: $0.filename, file: $0) }
                return ChangedFileGroup(
                    directory: directory,
                    files: named
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        .map(\.file)
                )
            }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }
}
