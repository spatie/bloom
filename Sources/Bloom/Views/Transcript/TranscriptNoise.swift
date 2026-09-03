import Foundation
import BloomCore

/// Whether a stored row is worth a line at all.
///
/// Rate-limit events already feed the menu bar's quota panel, so repeating them between messages
/// adds noise without adding information. Hook payloads can run to hundreds of kilobytes and are
/// skipped by sniffing the first bytes rather than decoding data that will not be shown.
enum TranscriptNoise {
    private static let probeLength = 256
    private static let hookMarker = Data("\"hook_".utf8)

    static func isHidden(_ row: TranscriptRow) -> Bool {
        if row.kind == .notice { return true }
        guard row.kind == .system else { return false }
        return row.payload.prefix(probeLength).range(of: hookMarker) != nil
    }
}
