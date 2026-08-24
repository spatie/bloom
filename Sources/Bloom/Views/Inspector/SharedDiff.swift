import Foundation
import CoreTransferable
import BloomCore

/// A diff as something `ShareLink` can hand to a sharing service.
///
/// The text is rendered on export rather than up front. `FileHeaderBar`'s body runs on every
/// keystroke in the editor beside it, and a four thousand line patch is only worth turning into a
/// message when somebody actually asks for one.
struct SharedDiff: Transferable {
    var file: ChangedFile
    /// Nil while the patch is still being read, which `DiffShareText` says so rather than
    /// pretending there is nothing to share.
    var diff: FileDiff?

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { DiffShareText.make(for: $0.file, diff: $0.diff) }
    }
}
