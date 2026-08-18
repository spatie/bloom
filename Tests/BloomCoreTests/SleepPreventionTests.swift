import Testing
@testable import BloomCore

@Suite("Sleep prevention")
struct SleepPreventionTests {
    @Test("holds the Mac open only while an agent is actually working")
    func needsBothHalves() {
        #expect(SleepPrevention.preventsSleep(isEnabled: true, runningCount: 1))
        #expect(SleepPrevention.preventsSleep(isEnabled: true, runningCount: 6))
        #expect(!SleepPrevention.preventsSleep(isEnabled: true, runningCount: 0))
    }

    @Test("lets the Mac sleep through a run when the setting is off")
    func respectsTheSwitch() {
        #expect(!SleepPrevention.preventsSleep(isEnabled: false, runningCount: 3))
        #expect(!SleepPrevention.preventsSleep(isEnabled: false, runningCount: 0))
    }

    @Test("is on out of the box, because it already was")
    func defaultsOn() {
        #expect(SleepPrevention.isOnByDefault)
    }

    @Test("says out loud that a closed lid still sleeps")
    func admitsTheLid() {
        #expect(SleepPrevention.caveat.contains("lid"))
        #expect(SleepPrevention.caveat.contains("battery"))
    }
}
