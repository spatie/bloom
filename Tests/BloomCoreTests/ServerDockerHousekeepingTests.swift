import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerDockerHousekeepingTests {
    private static let gibibyte: Int64 = 1_073_741_824
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thresholdIsFifteenPercentBetweenThreeAndTenGibibytes() {
        #expect(ServerDockerHousekeeping.threshold(totalBytes: 25 * Self.gibibyte) == Int64(Double(25 * Self.gibibyte) * 0.15))
        #expect(ServerDockerHousekeeping.threshold(totalBytes: 10 * Self.gibibyte) == 3 * Self.gibibyte)
        #expect(ServerDockerHousekeeping.threshold(totalBytes: 1_000 * Self.gibibyte) == 10 * Self.gibibyte)
        #expect(ServerDockerHousekeeping.threshold(totalBytes: nil) == 3 * Self.gibibyte)
    }

    @Test func theMeasuredServerCountsAsLowAndUnmeasuredSpaceNeverDoes() {
        // 25 GB with 87% used leaves about 3.3 GiB, which a bare 3 GiB floor would call healthy.
        let total = 25 * Self.gibibyte
        #expect(ServerDockerHousekeeping.isLow(totalBytes: total, freeBytes: total * 13 / 100) == true)
        #expect(ServerDockerHousekeeping.isLow(totalBytes: total, freeBytes: total / 2) == false)
        #expect(ServerDockerHousekeeping.isLow(totalBytes: total, freeBytes: nil) == nil)
    }

    @Test func setupPrunesOnlyDanglingImagesAtMostEveryTenMinutes() {
        var state = ServerDockerHousekeeping()
        let plenty = 20 * Self.gibibyte, total = 40 * Self.gibibyte
        let first = state.plan(.setupSucceeded, totalBytes: total, freeBytes: plenty, now: Self.start)
        #expect(first == [.danglingImages])
        #expect(first.flatMap(\.arguments) == ["image", "prune", "--force"])
        let soon = state.plan(.setupSucceeded, totalBytes: total, freeBytes: plenty, now: Self.start.addingTimeInterval(599))
        #expect(soon.isEmpty)
        let later = state.plan(.setupSucceeded, totalBytes: total, freeBytes: plenty, now: Self.start.addingTimeInterval(600))
        #expect(later == [.danglingImages])
        let healthyCheck = state.plan(.diskCheck, totalBytes: total, freeBytes: plenty, now: Self.start.addingTimeInterval(9_000))
        #expect(healthyCheck.isEmpty)
    }

    @Test func lowSpacePrunesCacheAndImagesHourlyAndEscalatesOnlyWhenStillLow() {
        var state = ServerDockerHousekeeping()
        let total = 25 * Self.gibibyte, low = 2 * Self.gibibyte
        let first = state.plan(.diskCheck, totalBytes: total, freeBytes: low, now: Self.start)
        #expect(first == [.danglingBuildCache, .danglingImages])
        #expect(!first.flatMap(\.arguments).contains("--all"))
        state.recordCleanup(totalBytes: total, freeBytes: low, now: Self.start)
        #expect(state.notice?.contains("2.0 GiB") == true)
        let withinHour = state.plan(.diskCheck, totalBytes: total, freeBytes: low, now: Self.start.addingTimeInterval(3_599))
        #expect(withinHour.isEmpty)
        let nextHour = state.plan(.diskCheck, totalBytes: total, freeBytes: low, now: Self.start.addingTimeInterval(3_600))
        #expect(nextHour == [.unusedBuildCache, .danglingImages])
        #expect(nextHour.allSatisfy { !$0.arguments.contains("volume") && !$0.arguments.contains("container") })
    }

    @Test func recoveredSpaceClearsTheNoticeAndTheEscalation() {
        var state = ServerDockerHousekeeping()
        let total = 25 * Self.gibibyte
        _ = state.plan(.diskCheck, totalBytes: total, freeBytes: Self.gibibyte, now: Self.start)
        state.recordCleanup(totalBytes: total, freeBytes: 12 * Self.gibibyte, now: Self.start)
        #expect(state.notice == nil)
        state.recordCleanup(totalBytes: total, freeBytes: Self.gibibyte, now: Self.start)
        let healthy = state.plan(.diskCheck, totalBytes: total, freeBytes: 12 * Self.gibibyte, now: Self.start.addingTimeInterval(60))
        #expect(healthy.isEmpty)
        #expect(state.notice == nil)
        let lowAgain = state.plan(.diskCheck, totalBytes: total, freeBytes: Self.gibibyte, now: Self.start.addingTimeInterval(7_200))
        #expect(lowAgain.first == .danglingBuildCache)
    }

    @Test func lowSpaceDuringSetupDoesNotPruneImagesTwice() {
        var state = ServerDockerHousekeeping()
        let plan = state.plan(.setupSucceeded, totalBytes: 25 * Self.gibibyte, freeBytes: Self.gibibyte, now: Self.start)
        #expect(plan == [.danglingBuildCache, .danglingImages])
    }

    @Test func aClockThatMovedBackwardsDoesNotHoldCleanupOff() {
        var state = ServerDockerHousekeeping()
        _ = state.plan(.setupSucceeded, totalBytes: nil, freeBytes: 100 * Self.gibibyte, now: Self.start)
        let earlier = state.plan(.setupSucceeded, totalBytes: nil, freeBytes: 100 * Self.gibibyte, now: Self.start.addingTimeInterval(-86_400))
        #expect(earlier == [.danglingImages])
    }

    @Test func diskCheckCarriesTheCleanupNoticeAtTheSameThreshold() {
        let total = UInt64(25 * Self.gibibyte)
        let measured = ServerDiagnosticsCollector.disk(freeBytes: total * 13 / 100, totalBytes: total)
        #expect(measured.status == .attention)
        let healthy = ServerDiagnosticsCollector.disk(freeBytes: total / 2, totalBytes: total)
        #expect(healthy.status == .ready)
        let noticed = ServerDiagnosticsCollector.disk(freeBytes: total / 2, totalBytes: total, cleanupNotice: "Automatic Docker cleanup ran.")
        #expect(noticed.status == .attention)
        #expect(noticed.detail.hasSuffix("Automatic Docker cleanup ran."))
    }

    @Test func housekeeperRunsThePlanAndRecordsWhatIsLeft() async {
        let recorder = PruneRecorder()
        let space = SpaceSequence([2 * Self.gibibyte, 2 * Self.gibibyte])
        let housekeeper = ServerDockerHousekeeper(disk: { (25 * Self.gibibyte, space.next()) },
            prune: { await recorder.record($0) }, now: { Self.start })
        await housekeeper.run(.setupSucceeded)
        #expect(await recorder.prunes == [.danglingBuildCache, .danglingImages])
        #expect(await housekeeper.notice != nil)
        await housekeeper.run(.setupSucceeded)
        #expect(await recorder.prunes.count == 2)
    }

    @Test func housekeeperSkipsQuietlyWhenDockerCannotBeReached() async {
        let housekeeper = ServerDockerHousekeeper(disk: { (nil, nil) }, prune: { _ in false }, now: { Self.start })
        await housekeeper.run(.diskCheck)
        await housekeeper.run(.setupSucceeded)
        #expect(await housekeeper.notice == nil)
    }
}

private actor PruneRecorder {
    var prunes: [ServerDockerHousekeeping.Prune] = []
    func record(_ prune: ServerDockerHousekeeping.Prune) -> Bool {
        prunes.append(prune)
        return true
    }
}

private final class SpaceSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}
