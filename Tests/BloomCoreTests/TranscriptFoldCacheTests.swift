import Testing
@testable import BloomCore

@Suite("Transcript fold analysis survives workspace switches")
struct TranscriptFoldCacheTests {
    private func tool(_ seq: Int, settled: Bool = true) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse, settled: settled)
    }

    @Test func unchangedReturnDoesNotReadFactsAgain() {
        var cache = TranscriptFoldCache()
        let facts = [tool(0), tool(1), tool(2), TranscriptFold.Fact(seq: 3, kind: .result)]
        var reads = 0
        let projected = facts.lazy.map { fact in
            reads += 1
            return fact
        }
        let first = cache.resolve(projected)
        #expect(reads > 0)
        reads = 0
        #expect(cache.resolve(projected) == first)
        #expect(reads == 0)
    }

    @Test func backgroundAppendOnlyScansBeyondCompletedTurn() {
        var cache = TranscriptFoldCache()
        var facts = [tool(0), tool(1), tool(2), TranscriptFold.Fact(seq: 3, kind: .result)]
        _ = cache.resolve(facts)
        cache.invalidate(row: facts.count)
        facts += [TranscriptFold.Fact(seq: 4, kind: .user), tool(5), tool(6), tool(7)]
        var scanned: [Int] = []
        let returned = cache.resolve(facts.lazy.map { fact in
            scanned.append(fact.seq)
            return fact
        })
        #expect(returned == TranscriptFold.folds(in: facts))
        #expect(!scanned.contains(where: { $0 < 4 }))
    }

    @Test func backgroundResultAndPermissionResolutionRefreshWithoutAppending() {
        var cache = TranscriptFoldCache()
        var facts = [tool(0, settled: false), tool(1), tool(2),
                     TranscriptFold.Fact(seq: 3, kind: .permissionAsk, settled: false)]
        let before = cache.resolve(facts)
        facts[0].settled = true
        cache.invalidate(row: 0)
        facts[3].settled = true
        cache.invalidate(row: 3)
        let after = cache.resolve(facts)
        #expect(after != before)
        #expect(after == TranscriptFold.folds(in: facts))
        #expect(after.scannedRows == before.scannedRows)
    }

    @Test func lateResultBeforeCompletedBoundaryInvalidatesSettledPrefix() {
        var cache = TranscriptFoldCache()
        var facts = [tool(0), tool(1), tool(2), TranscriptFold.Fact(seq: 3, kind: .result)]
        _ = cache.resolve(facts)
        facts[0].featured = true
        cache.invalidate(row: 0)
        #expect(cache.resolve(facts) == TranscriptFold.folds(in: facts))
    }

    @Test func replacementWithSameRowCountStartsFresh() {
        var cache = TranscriptFoldCache()
        let old = [tool(0), tool(1), tool(2)]
        _ = cache.resolve(old)
        let replacement = old.map { TranscriptFold.Fact(seq: $0.seq, kind: .assistantText) }
        cache.reset()
        #expect(cache.resolve(replacement) == TranscriptFold.folds(in: replacement))
        #expect(cache.resolve(replacement).all.isEmpty)
    }

    @Test func independentSessionsWithEqualRowCountsNeverShareAnalysis() {
        var first = TranscriptFoldCache()
        var second = TranscriptFoldCache()
        let tools = [tool(0), tool(1), tool(2)]
        let prose = tools.map { TranscriptFold.Fact(seq: $0.seq, kind: .assistantText) }
        let folded = first.resolve(tools)
        #expect(!folded.all.isEmpty)
        #expect(second.resolve(prose).all.isEmpty)
        #expect(first.resolve(tools) == folded)
    }
}
