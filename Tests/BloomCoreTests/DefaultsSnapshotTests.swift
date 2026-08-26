import Foundation
import Testing
@testable import BloomCore

/// The launch scans read this instead of `dictionaryRepresentation()`, so the two things that
/// would make that swap wrong are written down: a written key must be in it, and a registered key
/// must be known to be missing from it.
@Suite("DefaultsSnapshot")
struct DefaultsSnapshotTests {
    private func domain() -> (name: String, defaults: UserDefaults) {
        let name = "bloom.test.snapshot.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func clean(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("a written key is in the snapshot and the global domain is not")
    func ownKeysOnly() {
        let (name, defaults) = domain()
        defer { clean(name) }
        defaults.set("v", forKey: "center.tab.s1")

        let snapshot = DefaultsSnapshot.own(defaults, name: name)

        #expect(snapshot["center.tab.s1"] as? String == "v")
        // The whole point of the swap. `AppleLanguages` is in `dictionaryRepresentation()` for any
        // domain, because that merges `NSGlobalDomain` in, and it is not in this one.
        #expect(defaults.dictionaryRepresentation()["AppleLanguages"] != nil)
        #expect(snapshot["AppleLanguages"] == nil)
    }

    /// The trap the swap could have walked into: a registration domain is not a persistent one, so
    /// a key supplied that way is invisible here and a prefix scan would silently drop it.
    @Test("a registered key is not in the snapshot")
    func registeredKeysAreAbsent() {
        let (name, defaults) = domain()
        defer { clean(name) }
        defaults.register(defaults: ["center.tab.registered": "v"])

        #expect(defaults.string(forKey: "center.tab.registered") == "v")
        #expect(DefaultsSnapshot.own(defaults, name: name)["center.tab.registered"] == nil)
    }

    /// An unbundled binary has no domain name to ask for, and it still has to see its own keys.
    @Test("no domain name falls back to the merged representation")
    func namelessFallsBack() {
        let (name, defaults) = domain()
        defer { clean(name) }
        defaults.set("v", forKey: "center.tab.s1")

        #expect(DefaultsSnapshot.own(defaults, name: nil)["center.tab.s1"] as? String == "v")
    }
}
