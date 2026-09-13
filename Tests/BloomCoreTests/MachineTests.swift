import Testing
@testable import BloomCore

@Suite("Machine")
struct MachineTests {
    /// The lid question, and the reason the model name is the last thing consulted rather than the
    /// first: an Apple Silicon MacBook Pro reports `Mac16,6`, which looks exactly like a desktop.
    @Test("a lid is found from the hardware, and only then from the name")
    func portables() {
        #expect(Machine.isPortable(model: "Mac16,6", hasInternalBattery: true, publishesClamshellState: false))
        #expect(Machine.isPortable(model: "Mac16,6", hasInternalBattery: false, publishesClamshellState: true))
        #expect(Machine.isPortable(model: "MacBookPro18,3", hasInternalBattery: false, publishesClamshellState: false))
        #expect(!Machine.isPortable(model: "Mac16,6", hasInternalBattery: false, publishesClamshellState: false))
        #expect(!Machine.isPortable(model: "Macmini9,1", hasInternalBattery: false, publishesClamshellState: false))
        // An answer nobody gave offers nothing, rather than offering something that cannot work.
        #expect(!Machine.isPortable(model: "", hasInternalBattery: false, publishesClamshellState: false))
    }
}
