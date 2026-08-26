import Foundation

/// Which of the two transcripts this launch draws. **Spike only.**
///
/// The lazy stack and the table are both in the binary so that one run can be compared with the
/// next on the same machine, the same session and the same window size, which is the whole reason
/// this spike exists. The table is the default here because that is what is being measured; the
/// stack is one flag away and is what every other branch has.
///
///     Bloom --transcript-lazy      the `LazyVStack` this branch is being weighed against
///     Bloom --transcript-table     the `NSTableView` (the default on this branch)
///
/// A launch argument rather than a setting, because a probe already launches the app with a list
/// of them and nothing about this is a preference anybody should keep.
enum TranscriptVariant {
    static let usesTable: Bool = {
        if CommandLine.arguments.contains("--transcript-lazy") { return false }
        return true
    }()
}
