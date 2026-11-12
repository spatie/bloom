import Testing
import Foundation
@testable import BloomCore

@Suite("Chat advisor", .tags(.agentProtocol), .scratchDirectory)
struct ChatAdvisorTests {
    @Test("Default follows Settings, whatever Settings says", arguments: ClaudeAdvisor.allCases)
    func defaultFollowsSettings(appWide: ClaudeAdvisor) {
        #expect(ChatAdvisor.appDefault.resolved(over: appWide) == .consult(appWide))
    }

    @Test("a model chosen for the chat wins over Settings")
    func chosenModelWins() {
        #expect(ChatAdvisor.sonnet.resolved(over: .opus) == .consult(.sonnet))
        #expect(ChatAdvisor.fable.resolved(over: .inherit) == .consult(.fable))
    }

    @Test("Off wins even when Settings names a model")
    func offWins() {
        #expect(ChatAdvisor.off.resolved(over: .opus) == .off)
    }

    /// No row is what lets a later change in Settings reach a chat left on Default.
    @Test("Default is stored as no row, and no row reads back as Default")
    func defaultStoresNothing() {
        #expect(ChatAdvisor.appDefault.storedValue == nil)
        #expect(ChatAdvisor(stored: nil) == .appDefault)
        #expect(ChatAdvisor(stored: "nonsense") == .appDefault)
        #expect(ChatAdvisor(stored: ChatAdvisor.off.storedValue) == .off)
    }

    @Test("only Off disables the tool, and it states no model")
    func offEnvironment() {
        let base = ["PATH": "/usr/bin"]
        #expect(AdvisorLaunch.off.applying(to: base)[AdvisorLaunch.disableVariable] == "1")
        #expect(AdvisorLaunch.off.applying(to: base)["PATH"] == "/usr/bin")
        #expect(AdvisorLaunch.off.settingValue == nil)
        #expect(AdvisorLaunch.consult(.opus).applying(to: base) == base)
        #expect(AdvisorLaunch.consult(.opus).settingValue == "opus")
    }

    @Test("the store answer reads the chat's key over the app-wide one")
    func launchReadsBothKeys() async throws {
        let store = try makeTestStore("chat-advisor")
        let sessionID = SessionID("chat")
        try await store.setSetting(AppDefaults.Key.advisor, ClaudeAdvisor.opus.rawValue)
        #expect(await ChatAdvisor.launch(sessionID: sessionID, in: store) == .consult(.opus))

        try await store.setSetting(ChatAdvisor.key(sessionID: sessionID), ChatAdvisor.off.rawValue)
        #expect(await ChatAdvisor.launch(sessionID: sessionID, in: store) == .off)
    }

    /// The key is in the user's database once written.
    @Test("the advisor key is stable")
    func keyIsStable() {
        #expect(ChatAdvisor.key(sessionID: SessionID("abc")) == "session.abc.advisor")
    }
}
