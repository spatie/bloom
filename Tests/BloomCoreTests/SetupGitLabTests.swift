import Foundation
import Testing
@testable import BloomCore

@Suite("GitLab in onboarding")
struct SetupGitLabTests {
    private func report(gitHub: SetupOutcome, gitLab: SetupOutcome) -> SetupReport {
        SetupReport(checks: [
            SetupCheck(tool: .git, outcome: .ready(detail: "2.51.0")),
            SetupCheck(tool: .claudeCode, outcome: .ready(detail: nil)),
            SetupCheck(tool: .codex, outcome: .missing),
            SetupCheck(tool: .grok, outcome: .missing),
            SetupCheck(tool: .gitHub, outcome: gitHub),
            SetupCheck(tool: .gitLab, outcome: gitLab),
        ])
    }

    @Test("a missing glab changes neither the verdict nor its sentence")
    func optional() {
        let without = report(gitHub: .missing, gitLab: .missing)
        let with = report(gitHub: .missing, gitLab: .ready(detail: nil))
        #expect(without.verdict == with.verdict)
        #expect(without.sentence == with.sentence)
        #expect(!without.sentence.contains("GitLab"))
        #expect(without.severity(for: .gitLab) == .note)
        #expect(without.blocking.isEmpty)
    }

    @Test("a GitHub user with everything but glab is still all set")
    func allSetWithoutGlab() {
        let report = SetupReport(checks: [
            SetupCheck(tool: .git, outcome: .ready(detail: "2.51.0")),
            SetupCheck(tool: .claudeCode, outcome: .ready(detail: nil)),
            SetupCheck(tool: .codex, outcome: .ready(detail: nil)),
            SetupCheck(tool: .grok, outcome: .ready(detail: nil)),
            SetupCheck(tool: .gitHub, outcome: .ready(detail: "Signed in")),
            SetupCheck(tool: .gitLab, outcome: .missing),
        ])
        #expect(report.verdict == .ready)
        #expect(report.headline == "You are all set")
    }

    @Test("installing and signing in go the way gh's do")
    func fixes() {
        #expect(SetupCheck(tool: .gitLab, outcome: .missing).fix?.command == "brew install glab")
        #expect(SetupCheck(tool: .gitLab, outcome: .missing).fix?.isInteractive == false)
        let signIn = SetupCheck(tool: .gitLab, outcome: .needsSignIn(detail: nil)).fix
        #expect(signIn?.command == "glab auth login")
        #expect(signIn?.isInteractive == true)
    }

    @Test("signed in to one host is ready, even when another host fails")
    func status() {
        let output = """
        gitlab.com
          x gitlab.com: API call failed: 401 Unauthorized
        git.example.com
          ✓ Logged in to git.example.com as someone (/Users/someone/.config/glab-cli/config.yml)
        """
        #expect(SetupProbe.gitLabOutcome(signedIn: GitLabIdentity.parse(output)) == .ready(detail: "Signed in to git.example.com"))
        #expect(SetupProbe.gitLabOutcome(signedIn: [:]) == .needsSignIn(detail: nil))
    }
}

@Suite("GitLab identity")
struct GitLabIdentityTests {
    @Test("each signed in host gives its username, and a failing host gives none")
    func parse() {
        let output = """
        gitlab.com
          x gitlab.com: API call failed: 401 Unauthorized
        git.example.com
          ✓ Logged in to git.example.com as someone (/Users/someone/.config/glab-cli/config.yml)
        """
        #expect(GitLabIdentity.parse(output) == ["git.example.com": "someone"])
    }
}

@Suite("glab's configured hosts")
struct GlabHostsTests {
    @Test("the keys of the hosts map, and nothing nested under them")
    func hosts() {
        let config = """
        # glab config
        git_protocol: ssh
        hosts:
            gitlab.com: # work
                api_protocol: https
                token: secret
            git.example.com:
                user: someone
        editor: vim
        """
        #expect(GitLabIdentity.hosts(inConfig: config) == ["gitlab.com", "git.example.com"])
    }

    @Test("GLAB_CONFIG_DIR wins over the default place, as it does for glab")
    func configDirectory() throws {
        let directory = TestScratch.unique("glab-config")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "hosts:\n  only.example:\n    user: a\n".write(toFile: "\(directory)/config.yml", atomically: true, encoding: .utf8)
        #expect(GitLabIdentity.configuredHosts(environment: ["GLAB_CONFIG_DIR": directory], home: "/nonexistent") == ["only.example"])
    }
}
