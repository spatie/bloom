import Foundation
import BloomCore
import BloomClient

/// Whether a stored row is worth a line at all.
///
/// Rate-limit events already feed the menu bar's quota panel, so repeating them between messages
/// adds noise without adding information. Hook payloads can run to hundreds of kilobytes and are
/// skipped by sniffing the first bytes rather than decoding data that will not be shown.
enum TranscriptNoise {
    static func isHidden(_ row: TranscriptRow) -> Bool {
        TranscriptVisibility.hidesNoise(kind: row.kind.rawValue, payload: row.payload)
    }
}
