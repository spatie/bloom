import Testing
import Foundation
@testable import BloomCore

// MARK: - Fixtures

private func report(
    git: SetupOutcome = .ready(detail: "2.51.0"),
    claude: SetupOutcome = .ready(detail: "freek@spatie.be"),
    codex: SetupOutcome = .ready(detail: "freek@spatie.be"),
    gitHub: SetupOutcome = .ready(detail: "Signed in")
) -> SetupReport {
    SetupReport(checks: [
        SetupCheck(tool: .git, outcome: git),
        SetupCheck(tool: .claudeCode, outcome: claude),
        SetupCheck(tool: .codex, outcome: codex),
        SetupCheck(tool: .gitHub, outcome: gitHub),
    ])
}

// MARK: - The verdict

@Suite("Setup verdict")
struct SetupVerdictTests {
    @Test("a fresh report has looked at nothing")
    func pendingReport() {
        let pending = SetupReport.pending
        #expect(pending.checks.count == SetupTool.allCases.count)
        #expect(!pending.isSettled)
        #expect(pending.verdict == .checking)
    }

    @Test("one outstanding check keeps the whole report checking")
    func oneOutstanding() {
        #expect(report(gitHub: .pending).verdict == .checking)
    }

    @Test("everything installed and signed in reads as ready")
    func allClear() {
        #expect(report().verdict == .ready)
        #expect(report().blocking.isEmpty)
    }

    @Test("either agent alone is enough")
    func eitherAgent() {
        #expect(report(codex: .missing).hasRunnableAgent)
        #expect(report(claude: .missing).hasRunnableAgent)
        #expect(report(codex: .missing).verdict == .readyWithNotes)
        #expect(report(claude: .missing).verdict == .readyWithNotes)
    }

    @Test("neither agent is the one thing that blocks a machine that has git")
    func noAgent() {
        let blocked = report(claude: .missing, codex: .missing)
        #expect(!blocked.hasRunnableAgent)
        #expect(blocked.verdict == .blocked)
        #expect(blocked.blocking.map(\.tool) == [.claudeCode, .codex])
    }

    @Test("an agent that is installed and signed out does not count as runnable")
    func signedOutAgent() {
        let blocked = report(claude: .needsSignIn(detail: "2.1.234"), codex: .missing)
        #expect(blocked.verdict == .blocked)
    }

    @Test("no git blocks whatever else is present")
    func noGit() {
        #expect(report(git: .missing).verdict == .blocked)
        #expect(report(git: .missing).blocking.map(\.tool) == [.git])
    }

    @Test("a missing GitHub CLI is never a failure")
    func gitHubIsOptional() {
        let notes = report(gitHub: .missing)
        #expect(notes.verdict == .readyWithNotes)
        #expect(notes.blocking.isEmpty)
        #expect(notes.severity(for: .gitHub) == .note)
    }
}

// MARK: - Severity

@Suite("Setup severity")
struct SetupSeverityTests {
    @Test("a missing agent is a note while the other one is still being looked at")
    func quietWhileChecking() {
        let midway = report(claude: .missing, codex: .pending)
        #expect(midway.severity(for: .claudeCode) == .note)
    }

    @Test("a missing agent is a note when the other one answered")
    func quietWhenCovered() {
        #expect(report(codex: .missing).severity(for: .codex) == .note)
    }

    @Test("a missing agent is a problem only when it was the last one")
    func loudWhenAlone() {
        let blocked = report(claude: .missing, codex: .missing)
        #expect(blocked.severity(for: .claudeCode) == .problem)
        #expect(blocked.severity(for: .codex) == .problem)
    }

    @Test("everything that is ready is quiet")
    func readyIsQuiet() {
        for tool in SetupTool.displayOrder {
            #expect(report().severity(for: tool) == .ok)
        }
    }
}

// MARK: - The copy

@Suite("Setup copy")
struct SetupCopyTests {
    @Test("the all clear says so rather than listing what was checked")
    func allClearCopy() {
        #expect(report().headline == "You are all set")
        #expect(report().sentence.contains("installed and signed in"))
        #expect(report().primaryButtonTitle == "Start using Bloom")
    }

    @Test("an optional tool that is not set up is named")
    func namesTheQuietOne() {
        #expect(report(gitHub: .missing).sentence.contains("GitHub CLI"))
        #expect(report(codex: .missing).sentence.contains("Codex"))
    }

    @Test("a sentence naming the one tool with an article still starts with a capital")
    func capitalisesTheArticle() {
        #expect(report(gitHub: .missing).sentence.contains("The GitHub CLI is not set up"))
    }

    @Test("two quiet tools are joined with and, not with a comma")
    func joinsTwo() {
        let sentence = report(codex: .missing, gitHub: .missing).sentence
        #expect(sentence.contains("Codex and the GitHub CLI"))
    }

    @Test("the button is named after what pressing it does, even mid-check")
    func checkingIsNotAButtonTitle() {
        #expect(SetupReport.pending.verdict == .checking)
        #expect(SetupReport.pending.primaryButtonTitle == "Start using Bloom")
    }

    @Test("an optional tool that is not set up says what is still on")
    func saysWhatIsStillOn() {
        #expect(report(gitHub: .missing).sentence.contains("only the parts that use it are off"))
        let two = report(codex: .missing, gitHub: .missing).sentence
        #expect(two.contains("only the parts that use them are off"))
    }

    @Test("a blocked machine is offered another look rather than a closed door")
    func blockedCopy() {
        let blocked = report(claude: .missing, codex: .missing)
        #expect(blocked.headline == "Nearly there")
        #expect(blocked.primaryButtonTitle == "Check again")
    }

    @Test("no git and no agent says both, not one")
    func blockedOnBoth() {
        let blocked = report(git: .missing, claude: .missing, codex: .missing)
        #expect(blocked.sentence.contains("git and an agent"))
    }

    @Test("no headline or sentence carries a dash the house rules ban")
    func noDashes() {
        let cases = [
            report(),
            report(gitHub: .missing),
            report(claude: .missing),
            report(git: .missing),
            report(claude: .missing, codex: .missing),
            SetupReport.pending,
        ]
        for one in cases {
            #expect(!one.headline.contains("\u{2014}"))
            #expect(!one.sentence.contains("\u{2014}"))
            #expect(!one.sentence.contains("\u{2013}"))
        }
    }
}

// MARK: - The fix

@Suite("Setup fixes")
struct SetupFixTests {
    @Test("nothing that is ready offers a fix")
    func readyHasNoFix() {
        for tool in SetupTool.displayOrder {
            #expect(SetupCheck(tool: tool, outcome: .ready(detail: nil)).fix == nil)
        }
    }

    @Test("nothing that has not been looked at offers a fix")
    func pendingHasNoFix() {
        for tool in SetupTool.displayOrder {
            #expect(SetupCheck(tool: tool, outcome: .pending).fix == nil)
        }
    }

    @Test("every unsettled tool has something to do about it")
    func everythingBrokenHasAFix() {
        for tool in SetupTool.displayOrder {
            for outcome: SetupOutcome in [.missing, .needsSignIn(detail: nil)] {
                let fix = SetupCheck(tool: tool, outcome: outcome).fix
                #expect(fix != nil, "\(tool) \(outcome) has no fix")
                #expect(fix?.command?.isEmpty == false, "\(tool) \(outcome) has no command")
            }
        }
    }

    @Test("the install commands are the ones the tools' own docs give")
    func installCommands() {
        #expect(SetupCheck(tool: .git, outcome: .missing).fix?.command == "xcode-select --install")
        #expect(SetupCheck(tool: .claudeCode, outcome: .missing).fix?.command
            == "npm install -g @anthropic-ai/claude-code")
        #expect(SetupCheck(tool: .codex, outcome: .missing).fix?.command == "npm install -g @openai/codex")
        #expect(SetupCheck(tool: .gitHub, outcome: .missing).fix?.command == "brew install gh")
    }

    @Test("a sign in is the login command the agent itself declares")
    func signInCommands() {
        #expect(SetupCheck(tool: .claudeCode, outcome: .needsSignIn(detail: nil)).fix?.command
            == AgentKind.claudeCode.loginCommand)
        #expect(SetupCheck(tool: .codex, outcome: .needsSignIn(detail: nil)).fix?.command
            == AgentKind.codex.loginCommand)
        #expect(SetupCheck(tool: .gitHub, outcome: .needsSignIn(detail: nil)).fix?.command
            == "gh auth login")
    }

    @Test("only the interactive commands claim Bloom can run them")
    func interactivity() {
        #expect(SetupCheck(tool: .gitHub, outcome: .needsSignIn(detail: nil)).fix?.isInteractive == true)
        #expect(SetupCheck(tool: .claudeCode, outcome: .needsSignIn(detail: nil)).fix?.isInteractive == true)
        #expect(SetupCheck(tool: .gitHub, outcome: .missing).fix?.isInteractive == false)
        #expect(SetupCheck(tool: .git, outcome: .missing).fix?.isInteractive == false)
    }

    @Test("every install fix carries an address as well as a package manager")
    func installsCarryAnAddress() {
        for tool in SetupTool.displayOrder {
            #expect(SetupCheck(tool: tool, outcome: .missing).fix?.url != nil, "\(tool)")
        }
    }
}

// MARK: - The tools

@Suite("Setup tools")
struct SetupToolTests {
    @Test("the agent rows name agents Bloom can actually drive")
    func agentsAreRunnable() {
        #expect(SetupTool.claudeCode.agentKind?.canRunWorkspaces == true)
        #expect(SetupTool.codex.agentKind?.canRunWorkspaces == true)
        #expect(SetupTool.git.agentKind == nil)
        #expect(SetupTool.gitHub.agentKind == nil)
    }

    @Test("every agent Bloom can drive has a row, so a new backend cannot be forgotten")
    func everyRunnableAgentIsListed() {
        let listed = Set(SetupTool.displayOrder.compactMap(\.agentKind))
        #expect(listed == Set(AgentKind.runnable))
    }

    @Test("the display order holds every tool exactly once")
    func displayOrderIsComplete() {
        #expect(Set(SetupTool.displayOrder) == Set(SetupTool.allCases))
        #expect(SetupTool.displayOrder.count == SetupTool.allCases.count)
    }

    @Test("the executables are the names these CLIs actually install")
    func executables() {
        #expect(SetupTool.git.executableName == "git")
        #expect(SetupTool.gitHub.executableName == "gh")
        #expect(SetupTool.claudeCode.executableName == AgentKind.claudeCode.executableName)
        #expect(SetupTool.codex.executableName == AgentKind.codex.executableName)
    }
}

// MARK: - Whether the window opens

@Suite("Onboarding gate")
struct OnboardingGateTests {
    @Test("a first launch opens the window before anything has been probed")
    func firstRun() {
        #expect(OnboardingGate.trigger(hasCompletedBefore: false, verdict: nil) == .firstRun)
        #expect(OnboardingGate.trigger(hasCompletedBefore: false, verdict: .ready) == .firstRun)
        #expect(OnboardingGate.trigger(hasCompletedBefore: false, verdict: .blocked) == .firstRun)
    }

    @Test("a machine that is fine never sees it again")
    func staysShut() {
        #expect(OnboardingGate.trigger(hasCompletedBefore: true, verdict: .ready) == .none)
        #expect(OnboardingGate.trigger(hasCompletedBefore: true, verdict: .readyWithNotes) == .none)
        #expect(OnboardingGate.trigger(hasCompletedBefore: true, verdict: nil) == .none)
    }

    @Test("a machine that has stopped working gets it back")
    func returnsWhenBroken() {
        #expect(OnboardingGate.trigger(hasCompletedBefore: true, verdict: .blocked) == .blocked)
    }

    @Test("a half finished probe never re-opens the window")
    func neverOnAPartialAnswer() {
        #expect(OnboardingGate.trigger(hasCompletedBefore: true, verdict: .checking) == .none)
    }
}

// MARK: - The account line

@Suite("Setup account line")
struct SetupAccountLineTests {
    @Test("the email is what a connected agent is labelled with")
    func prefersEmail() {
        let status = AgentStatus(
            kind: .claudeCode,
            connection: .connected,
            version: "2.1.234",
            details: [
                AgentDetail(label: "Organization", value: "Spatie"),
                AgentDetail(label: "Email", value: "freek@spatie.be"),
            ]
        )
        #expect(SetupProbe.accountLine(status) == "freek@spatie.be")
    }

    @Test("an unknown field is skipped rather than printed")
    func skipsUnknown() {
        let status = AgentStatus(
            kind: .claudeCode,
            connection: .connected,
            version: "2.1.234",
            details: [
                AgentDetail(label: "Email", value: AgentCatalog.unknown),
                AgentDetail(label: "Organization", value: "Spatie"),
            ]
        )
        #expect(SetupProbe.accountLine(status) == "Spatie")
    }

    @Test("with no account fact at all it falls back to the version")
    func fallsBackToVersion() {
        let status = AgentStatus(kind: .codex, connection: .connected, version: "0.147.0", details: [])
        #expect(SetupProbe.accountLine(status) == "0.147.0")
    }
}
