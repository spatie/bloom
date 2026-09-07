import Foundation
import Testing
@testable import BloomCore

@Suite("Message arrival continuity")
struct MessageArrivalTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test func sentBubbleLiftsAndSettlesWithoutOvershoot() {
        let arrival = MessageArrival(style: .sent, startedAt: start)
        let first = arrival.pose(at: start, reduceMotion: false)
        #expect(first.opacity == 0)
        #expect(first.rise == 10)
        #expect(first.scale == 0.975)
        let middle = arrival.pose(at: start.addingTimeInterval(0.16), reduceMotion: false)
        #expect(middle.opacity > 0 && middle.opacity < 1)
        #expect(middle.rise > 0 && middle.rise < 10)
        #expect(middle.scale > first.scale && middle.scale < 1)
        #expect(arrival.pose(at: start.addingTimeInterval(1), reduceMotion: false) == .settled)
    }

    @Test func repliesOnlyFade() {
        let pose = MessageArrival(style: .reply, startedAt: start)
            .pose(at: start.addingTimeInterval(0.1), reduceMotion: false)
        #expect(pose.opacity > 0 && pose.opacity < 1)
        #expect(pose.rise == 0)
        #expect(pose.scale == 1)
    }

    @Test func reduceMotionAlwaysDrawsTheFinishedMessage() {
        for style in [MessageArrival.Style.sent, .reply] {
            #expect(MessageArrival(style: style, startedAt: start)
                .pose(at: start, reduceMotion: true) == .settled)
        }
    }

    @Test func aClockMovingBackwardsCannotExtendTheAnimation() {
        let arrival = MessageArrival(style: .sent, startedAt: start)
        #expect(arrival.remaining(at: start.addingTimeInterval(-5)) == arrival.duration)
    }

    @Test func loadingHistoryDoesNotCreateArrivals() {
        let arrivals = MessageArrivals()
        #expect(arrivals.row(1) == nil)
        #expect(arrivals.delivery(DeliveryID("restored")) == nil)
        #expect(arrivals.stream(.assistantText) == nil)
    }

    @Test func savedBubbleResumesTheInstantEchoInsteadOfFadingTwice() {
        var arrivals = MessageArrivals()
        let id = DeliveryID("sent")
        arrivals.sent(id, at: start)
        let echo = arrivals.delivery(id)
        arrivals.persisted(seq: 1, kind: .user, sending: id, at: start.addingTimeInterval(0.05))
        #expect(arrivals.row(1) == echo)
        #expect(arrivals.delivery(id) == nil)
    }

    @Test func queuedMessageDoesNotArriveAgainWhenItIsDelivered() {
        var arrivals = MessageArrivals()
        let id = DeliveryID("queued")
        arrivals.sent(id, at: start)
        arrivals.sent(DeliveryID("next"), at: start.addingTimeInterval(5))
        arrivals.persisted(seq: 1, kind: .user, sending: id, at: start.addingTimeInterval(10))
        #expect(arrivals.row(1) == nil)
    }

    @Test func streamedBlockKeepsItsClockWhenPersisted() {
        var arrivals = MessageArrivals()
        arrivals.beganStream(.assistantText, at: start)
        let live = arrivals.stream(.assistantText)
        arrivals.persisted(seq: 1, kind: .assistantText, at: start.addingTimeInterval(0.08))
        #expect(arrivals.row(1) == live)
        #expect(arrivals.stream(.assistantText) == nil)
        arrivals.beganStream(.assistantText, at: start.addingTimeInterval(1))
        #expect(arrivals.stream(.assistantText) != live)
    }

    @Test func longStreamDoesNotReplayWhenSaved() {
        var arrivals = MessageArrivals()
        arrivals.beganStream(.assistantText, at: start)
        let finish = start.addingTimeInterval(30)
        arrivals.persisted(seq: 1, kind: .assistantText, at: finish)
        #expect(arrivals.row(1)?.pose(at: finish, reduceMotion: false) == .settled)
    }

    @Test func nonStreamingReplyArrivesButToolsKeepTheirExistingEffect() {
        var arrivals = MessageArrivals()
        arrivals.persisted(seq: 1, kind: .assistantText, at: start)
        arrivals.persisted(seq: 2, kind: .toolUse, at: start)
        #expect(arrivals.row(1)?.startedAt == start)
        #expect(arrivals.row(2) == nil)
    }

    @Test func oldRowsExpireAndBurstsStayBounded() {
        var arrivals = MessageArrivals()
        for seq in 1...100 { arrivals.persisted(seq: seq, kind: .assistantText, at: start) }
        #expect(arrivals.row(36) == nil)
        #expect(arrivals.row(37) != nil)
        arrivals.persisted(seq: 101, kind: .assistantText, at: start.addingTimeInterval(1))
        #expect(arrivals.row(100) == nil)
        #expect(arrivals.row(101) != nil)
    }
}
