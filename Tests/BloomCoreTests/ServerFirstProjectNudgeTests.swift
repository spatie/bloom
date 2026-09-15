import Testing
@testable import BloomCore

/// The card that nudges an empty server towards its first project, and when it stays away.
@Suite("Server first project nudge")
struct ServerFirstProjectNudgeTests {
    private func resolve(
        isEnabled: Bool = true,
        isConnected: Bool = true,
        projectCount: Int? = 0,
        isRetired: Bool = false
    ) -> ServerFirstProjectNudge? {
        ServerFirstProjectNudge.resolve(
            isEnabled: isEnabled, isConnected: isConnected,
            projectCount: projectCount, isRetired: isRetired
        )
    }

    @Test("a connected empty server gets the card")
    func emptyServerGetsCard() {
        #expect(resolve() == .card)
    }

    @Test("a retired card leaves the plain sentence")
    func retiredLeavesNotice() {
        #expect(resolve(isRetired: true) == .notice)
    }

    /// Hidden projects are counted by the caller, so this is also the tidied server.
    @Test("a server with any project draws nothing extra")
    func projectsDrawNothing() {
        #expect(resolve(projectCount: 1) == nil)
        #expect(resolve(projectCount: 3, isRetired: true) == nil)
    }

    @Test("an unloaded catalogue is not an empty server")
    func unloadedCatalogue() {
        #expect(resolve(projectCount: nil) == nil)
    }

    /// Start a Project is disabled while the heading says why, so nothing offers it.
    @Test("nothing while disconnected, connecting or with servers switched off")
    func unavailableServer() {
        #expect(resolve(isConnected: false) == nil)
        #expect(resolve(isConnected: false, isRetired: true) == nil)
        #expect(resolve(isEnabled: false) == nil)
    }

    @Test("retiring a server is remembered and does not disturb the others")
    func retiringRoundTrips() {
        let first = ServerFirstProjectNudge.retiring("ssh\u{0}bloom-now\u{0}/srv/bloom", in: "")
        let second = ServerFirstProjectNudge.retiring("https\u{0}example.com", in: first)
        #expect(ServerFirstProjectNudge.retired(in: second) == ["ssh\u{0}bloom-now\u{0}/srv/bloom", "https\u{0}example.com"])
    }

    @Test("retiring the same server twice writes the same string")
    func retiringIsIdempotent() {
        let once = ServerFirstProjectNudge.retiring("b", in: ServerFirstProjectNudge.retiring("a", in: ""))
        let twice = ServerFirstProjectNudge.retiring("a", in: once)
        #expect(once == twice)
    }

    @Test("an unreadable stored value reads as nothing retired")
    func unreadableStoredValue() {
        #expect(ServerFirstProjectNudge.retired(in: "").isEmpty)
        #expect(ServerFirstProjectNudge.retired(in: "not json").isEmpty)
        #expect(ServerFirstProjectNudge.retiring("a", in: "not json") == #"["a"]"#)
    }
}
