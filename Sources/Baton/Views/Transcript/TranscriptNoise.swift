import Foundation
import BatonCore

/// Whether a stored row is worth a line at all.
///
/// Hook payloads run to hundreds of kilobytes and say nothing a user wants to read, so they are
/// skipped by sniffing the first bytes of the raw line rather than by decoding it. Decoding a
/// megabyte of hook output only to throw it away is exactly the cost this avoids.
enum TranscriptNoise {
    private static let probeLength = 256
    private static let hookMarker = Data("\"hook_".utf8)

    static func isHidden(_ row: TranscriptRow) -> Bool {
        guard row.kind == .system else { return false }
        return row.payload.prefix(probeLength).range(of: hookMarker) != nil
    }
}
