import Foundation
import BloomCore

/// The transcript's caches, filled before the table asks them anything.
///
/// Every expensive thing a row does is already a pure function over `Sendable` values:
/// `AgentEvent.decode`, `JSONValue.parse`, `TranscriptPresenter.present`, `MarkdownParser.parse`
/// and `CarryPass.states`. Every one of them ran on the main actor all the same, on a cache miss,
/// while the row it belonged to was being measured or drawn, and nothing filled them in advance.
/// So the whole of a session's parsing sat on the one thread that also has to lay it out.
///
/// It is safe for the reason `DiffView.prime` gives for `SyntaxCache`: the caches are `NSCache`s,
/// which do their own locking, and every value in them is a `final class` whose stored properties
/// are `let`s of `Sendable` value types. Nothing a reader takes out can be written by anybody, so
/// the second pass can happen before the first row is asked for.
///
/// **It moves no measuring.** An `NSHostingView` is laid out on the main thread by law, and that
/// is about 2.1ms a row. This makes each of those cheaper, and there are exactly as many of them
/// as there were.
///
/// It races the reader for the first screen and is meant to: both may compute the same row, and
/// the loser's answer is dropped by whichever `setObject` lands second. That is a few rows of
/// wasted microseconds once, and coalescing it would mean a lock the main thread has to take on
/// every lookup to save them.
enum TranscriptPrime {
    /// How many rows are prepared at once.
    ///
    /// The pass exists to be finished before the reader scrolls, not to use the machine. The main
    /// thread is measuring rows while it runs, every item allocates, and the caches take a lock
    /// per write, so a fan-out over four hundred rows buys contention rather than throughput. Four
    /// stays comfortably ahead of a reader and leaves the rest of the machine to the window.
    static let width = 4

    /// Fills the caches for the rows the list is about to draw.
    ///
    /// The same window the list will settle on, worked out with the same two functions it uses, so
    /// this cannot prepare a different four hundred rows from the ones asked for. `unreadSeq` is
    /// what moves that window off the live end, and it is also where the reader lands, which is
    /// why it decides the order as well.
    static func run(rows: [TranscriptRow], worktree: String, unreadSeq: Int?) async {
        guard !rows.isEmpty else { return }
        let unread = unreadSeq.flatMap {
            TranscriptWindow.index(ofSeqAtOrAfter: $0, in: rows.lazy.map(\.seq))
        }
        let window = TranscriptWindow.settling(
            from: .opening(
                rowCount: rows.count,
                tailStart: TranscriptTail.start(in: rows.lazy.map(\.kind)),
                mustReach: unread
            ),
            rowCount: rows.count
        )

        await withTaskGroup(of: Void.self) { group in
            var started = 0
            for index in window.indices(outwardFrom: unread ?? rows.count - 1) {
                if started >= width { _ = await group.next() }
                let row = rows[index]
                group.addTask { prime(row, worktree: worktree) }
                started += 1
            }
        }
    }

    /// What one row costs the first time anybody looks at it, done here instead.
    ///
    /// The switch is `TranscriptRowView`'s own, and has to stay it: a kind prepared through the
    /// wrong cache is work done twice rather than nought times. A notice is absent on purpose,
    /// because it is drawn from the payload itself and goes through no cache at all.
    private static func prime(_ row: TranscriptRow, worktree: String) {
        switch row.kind {
        // The bubble is read straight out of the stored request, and an error's exit out of the
        // same tree, so both want the JSON rather than the decoded event.
        case .user, .error:
            _ = TranscriptEventCache.json(rowID: row.id, payload: row.payload)
        case .notice:
            break
        default:
            guard let event = TranscriptEventCache.event(rowID: row.id, payload: row.payload) else {
                return
            }
            switch event {
            case .assistantText(let block):
                prose(block.text)
            case .toolUse(let use):
                _ = TranscriptPresentationCache.presentation(
                    rowID: row.id, use: use, worktree: worktree
                )
            default:
                break
            }
        }
    }

    /// An answer parsed, and the fences inside it split and carried.
    ///
    /// A thinking block is deliberately not here: it is one line until the reader opens it, so
    /// parsing every one of them would be work for a row nobody has asked to see.
    private static func prose(_ text: String) {
        guard !text.isEmpty else { return }
        fences(in: MarkdownPrime.blocks(of: text))
    }

    /// Every fence in a block tree, including the ones inside a list or a quote, which is where an
    /// agent's longest ones usually are.
    ///
    /// Table cells hold inline runs rather than blocks, so there is nothing under them to walk.
    private static func fences(in blocks: [MarkdownBlock]) {
        for block in blocks {
            switch block {
            case .codeBlock(let code, let language, _):
                CodeBlockPrime.prepare(code: code, language: language)
            case .blockQuote(let inner):
                fences(in: inner)
            case .bulletList(let items, _), .numberedList(_, let items, _):
                for item in items { fences(in: item) }
            default:
                break
            }
        }
    }
}
