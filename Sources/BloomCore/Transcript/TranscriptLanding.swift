import Foundation

/// Where a place naming a row lands once that row is no longer drawn, say folded into its turn's
/// line when the turn finished while the reader was on another tab. A scroll to an entry the
/// table does not hold went nowhere, and left a rebuilt table at its very top.
public enum TranscriptLanding {
    /// The row's own entry, or else the last entry drawn from a row before it: the fold now hiding
    /// it, or the row above. Nil when nothing is drawn from before it.
    public static func index(of seq: Int, in ids: [TranscriptEntryID]) -> Int? {
        if let exact = ids.firstIndex(of: .row(seq)) { return exact }
        var landing: (start: Int, index: Int)?
        for (index, id) in ids.enumerated() {
            guard let start = start(of: id), start <= seq, start >= (landing?.start ?? .min) else { continue }
            landing = (start, index)
        }
        return landing?.index
    }

    /// The row an entry is drawn from; a fold's is the first row of the run it covers.
    private static func start(of id: TranscriptEntryID) -> Int? {
        switch id {
        case .row(let seq), .answerPart(let seq, _), .fold(let seq), .turnFold(let seq): seq
        case .setup, .sending, .streaming, .pending, .bottomSpacing: nil
        }
    }
}
