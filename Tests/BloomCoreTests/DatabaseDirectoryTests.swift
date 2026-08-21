import Foundation
import Testing
@testable import BloomCore

/// Which database a binary is allowed to open, decided by which binary it is.
///
/// This is the one rule in Bloom whose failure costs the owner a real worktree. The fallback
/// directory used to be the constant "Bloom", so anything that got as far as `Store.defaultPath`
/// without `BLOOM_DB_PATH` opened the real database: the real projects, the real worktree paths,
/// and, through `TmuxSessions.fingerprint`, the real tmux socket. One archive click out of a dev
/// build removes a worktree and offers up its branch.
///
/// `Bundle.main` cannot be varied inside one process, which is why the table is a pure function of
/// the identifier and why this suite exists at all. The wiring above it is one line.
@Suite("Database directory")
struct DatabaseDirectoryTests {
    private func name(_ identifier: String?) -> String {
        Store.databaseDirectoryName(forBundleIdentifier: identifier)
    }

    @Test("the real app keeps the directory its data is already in")
    func theRealApp() {
        #expect(name(Store.primaryBundleIdentifier) == "Bloom")
        #expect(Store.primaryBundleIdentifier == "be.spatie.bloom")
    }

    /// `Tools/dev-build.sh` puts this same path in `LSEnvironment`, so the two agree and a dev
    /// binary started by hand lands where `make dev-db` put the copy rather than somewhere new.
    @Test("the dev copy lands where dev-build.sh already points it")
    func theDevCopy() {
        #expect(name(Store.devBundleIdentifier) == "Bloom Dev")
        #expect(Store.devBundleIdentifier == "be.spatie.bloom.dev")
    }

    /// The case nothing warned about. `swift run Bloom` and `.build/debug/Bloom` are not inside a
    /// bundle, so there is no identifier at all, and until this they resolved to the real database.
    @Test("a binary in no bundle gets a directory that says so")
    func unbundled() {
        #expect(name(nil) == "Bloom (unbundled)")
        #expect(name("") == "Bloom (unbundled)")
    }

    @Test("any other bundle is named after itself rather than sharing")
    func someOtherBundle() {
        #expect(name("be.spatie.bloom.snapshot") == "Bloom (be.spatie.bloom.snapshot)")
        #expect(name("com.apple.dt.xctest.tool") == "Bloom (com.apple.dt.xctest.tool)")
    }

    /// The property that matters is not what each one is called, it is that no two of them collide.
    @Test("no two identities share a directory")
    func noneCollide() {
        let identifiers: [String?] = [
            Store.primaryBundleIdentifier, Store.devBundleIdentifier,
            "be.spatie.bloom.snapshot", "be.spatie.bloomer", nil,
        ]
        let names = identifiers.map(name)
        #expect(Set(names).count == names.count)
    }

    /// A prefix of the real identifier is not the real identifier. `be.spatie.bloomer` would match
    /// a `hasPrefix` written in a hurry, and it must not.
    @Test("a near miss on the identifier is not a match")
    func aNearMissIsNotAMatch() {
        #expect(name("be.spatie.bloom.dev.extra") != "Bloom")
        #expect(name("be.spatie.bloom.dev.extra") != "Bloom Dev")
        #expect(name("be.spatie.bloomer") != "Bloom")
        #expect(name("BE.SPATIE.BLOOM") != "Bloom")
    }
}
