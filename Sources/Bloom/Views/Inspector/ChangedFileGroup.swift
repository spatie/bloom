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
    static func build(from files: [ChangedFile]) -> [ChangedFileGroup] {
        Dictionary(grouping: files, by: \.directory)
            .map { directory, files in
                ChangedFileGroup(
                    directory: directory,
                    files: files.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
                )
            }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }
}
