import Foundation
import Testing
@testable import BloomCore

/// Fixtures are the CLIs' own words: Claude Code's from the owner's screenshot and the strings in
/// version 2.1.270, gh's from its binary. Codex's device prompt could not be read out of its
/// binary, so its fixture is the shape every device flow prints, and the parser holds to that shape
/// rather than to a sentence.
@Suite("Remote sign-in reading")
struct RemoteSignInReadingTests {
    static let claudeURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=gNUWkpFkkWGqDX1TTW_bZ5k9Qaan1wm8d&state=elGBUfYUYoCvQa7"

    static let claudeScreen = """
    bloom-sign-in: installing
    npm warn deprecated something
    npm notice
    npm notice New major version of npm available! 11.17.0 -> 12.0.2
    npm notice Changelog: https://github.com/npm/cli/releases/tag/v12.0.2
    npm notice To update run: npm install -g npm@12.0.2
    npm notice
    Opening browser to sign in…
    If the browser didn't open, visit: \(claudeURL)
    Paste code here if prompted >
    """

    @Test func claudeLinkSkipsNpmChangelogAndWaitsForCode() {
        let reading = RemoteSignInReading(account: .claude, output: Self.claudeScreen)
        #expect(reading.link?.absoluteString == Self.claudeURL)
        #expect(reading.wantsPastedCode)
        #expect(!reading.hasPastedCode)
        #expect(!reading.isInstalling)
        #expect(reading.code == nil)
        #expect(RemoteSignInStep.decide(account: .claude, reading: reading, exit: nil) == .pasteCode(link: URL(string: Self.claudeURL)!))
    }

    @Test func claudeTypedCodeIsConfirming() {
        let screen = Self.claudeScreen + " abcDEF123#state456"
        let reading = RemoteSignInReading(account: .claude, output: screen)
        #expect(!reading.wantsPastedCode)
        #expect(reading.hasPastedCode)
        #expect(RemoteSignInStep.decide(account: .claude, reading: reading, exit: nil) == .confirming)
    }

    @Test func claudeSuccessIsReportedButNotTheVerdict() {
        let screen = Self.claudeScreen + " abc\nLogin successful."
        let reading = RemoteSignInReading(account: .claude, output: screen)
        #expect(reading.reportsSuccess)
        #expect(RemoteSignInStep.decide(account: .claude, reading: reading, exit: nil) == .confirming)
        #expect(RemoteSignInStep.decide(account: .claude, reading: reading, exit: .exited(0)) == .finished)
    }

    @Test func claudeInvalidCodeFailsInItsOwnWords() {
        let screen = Self.claudeScreen + " wrong\nOAuth error: Invalid code. Please make sure the full code was copied"
        let reading = RemoteSignInReading(account: .claude, output: screen)
        let step = RemoteSignInStep.decide(account: .claude, reading: reading, exit: .exited(1))
        #expect(step == .failed(message: "OAuth error: Invalid code. Please make sure the full code was copied"))
        #expect(step.needsTerminal)
    }

    @Test func installingUntilTheCliSpeaks() {
        let screen = "bloom-sign-in: installing\n\\\n|\nnpm warn deprecated inflight@1.0.6"
        let reading = RemoteSignInReading(account: .codex, output: screen)
        #expect(reading.isInstalling)
        #expect(RemoteSignInStep.decide(account: .codex, reading: reading, exit: nil) == .installing)
    }

    @Test func installFailureNamesTheTool() {
        let screen = "bloom-sign-in: installing\nnpm error code EACCES\nnpm error A complete log of this run can be found in: /home/bloom/.npm/_logs/x.log"
        let reading = RemoteSignInReading(account: .claude, output: screen)
        let step = RemoteSignInStep.decide(account: .claude, reading: reading, exit: .exited(243))
        #expect(step == .failed(message: "Claude Code could not be installed on the server. Check the terminal output, then try again."))
    }

    @Test func nothingYetIsConnecting() {
        let reading = RemoteSignInReading(account: .github, output: "")
        #expect(RemoteSignInStep.decide(account: .github, reading: reading, exit: nil) == .connecting)
    }

    @Test func githubAnswersTheGitQuestionItself() {
        let screen = "? Authenticate Git with your GitHub credentials? (Y/n)"
        let reading = RemoteSignInReading(account: .github, output: screen)
        #expect(reading.automaticReply == "\r")
        #expect(!reading.hasUnrecognisedPrompt)
    }

    @Test func githubDeviceCodeWaitsForReturn() {
        let screen = """
        ? Authenticate Git with your GitHub credentials? Yes

        ! First copy your one-time code: 3F2A-9BC1
        Press Enter to open https://github.com/login/device in your browser...
        """
        let reading = RemoteSignInReading(account: .github, output: screen)
        #expect(reading.code == "3F2A-9BC1")
        #expect(reading.link?.absoluteString == "https://github.com/login/device")
        #expect(reading.waitsForReturn)
        #expect(reading.automaticReply == nil)
        let step = RemoteSignInStep.decide(account: .github, reading: reading, exit: nil)
        #expect(step == .enterCode(code: "3F2A-9BC1", link: URL(string: "https://github.com/login/device")!, needsReturn: true))
    }

    @Test func githubAfterReturnKeepsTheCode() {
        let screen = """
        ! First copy your one-time code: 3F2A-9BC1
        Press Enter to open https://github.com/login/device in your browser...
        https://github.com/login/device
        """
        let reading = RemoteSignInReading(account: .github, output: screen)
        #expect(!reading.waitsForReturn)
        #expect(RemoteSignInStep.decide(account: .github, reading: reading, exit: nil)
            == .enterCode(code: "3F2A-9BC1", link: URL(string: "https://github.com/login/device")!, needsReturn: false))
    }

    @Test func githubCodeWithoutAnAddressFallsBackToTheDevicePage() {
        let reading = RemoteSignInReading(account: .github, output: "! First copy your one-time code: ABCD-1234")
        #expect(reading.link?.absoluteString == "https://github.com/login/device")
    }

    @Test func codexDeviceFlow() {
        let screen = """
        Follow these steps to sign in with ChatGPT using device code authorization:

        1. Open this link in your browser and sign in to your account
           https://auth.openai.com/codex/device

        2. Enter this one-time code after you are signed in
           WXYZ-ABCD

        Device codes are a common phishing target. Never share this code.
        """
        let reading = RemoteSignInReading(account: .codex, output: screen)
        #expect(RemoteSignInStep.decide(account: .codex, reading: reading, exit: nil)
            == .enterCode(code: "WXYZ-ABCD", link: URL(string: "https://auth.openai.com/codex/device")!, needsReturn: false))
    }

    @Test func unknownQuestionHandsOverToTheTerminal() {
        let reading = RemoteSignInReading(account: .claude, output: "Enter passphrase for key '/home/bloom/.ssh/id_ed25519':")
        #expect(reading.hasUnrecognisedPrompt)
        let step = RemoteSignInStep.decide(account: .claude, reading: reading, exit: nil)
        #expect(step == .unrecognised)
        #expect(step.needsTerminal)
    }

    @Test func versionNumbersAreNotCodes() {
        #expect(RemoteSignInReading.code(in: "node 2024-0612") == nil)
        #expect(RemoteSignInReading.code(in: "visit https://x.test/?a=ABCD-EFGH") == nil)
    }

    @Test func linkDropsTrailingPunctuation() {
        #expect(RemoteSignInReading.link(in: "Go to https://example.com/device.")?.absoluteString == "https://example.com/device")
    }

    @Test func commandsAnnounceTheirInstallation() {
        #expect(RemoteSignInAccount.claude.shellCommand.contains("echo '\(RemoteSignInAccount.installMarker)'"))
        #expect(RemoteSignInAccount.codex.shellCommand.contains("echo '\(RemoteSignInAccount.installMarker)'"))
        #expect(RemoteSignInAccount.codex.shellCommand.hasSuffix("codex login --device-auth"))
        #expect(RemoteSignInAccount.github.shellCommand.hasPrefix("GH_BROWSER=echo gh auth login"))
    }
}
