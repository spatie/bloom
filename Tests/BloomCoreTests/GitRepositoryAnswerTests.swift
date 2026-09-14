import Testing
import Foundation
@testable import BloomCore

/// A user's every repository was announced by Start a Project and refused by Add Project as "not
/// a git repository", because git itself could not run or would not read the folder and both were
/// reported as a folder that is not one. These pin the difference.
@Suite("Git repository answer")
struct GitRepositoryAnswerTests {
    private let path = "/Users/tester/dev/thing"

    @Test("git saying true or false is an answer, not a problem")
    func answered() {
        #expect(GitRepositoryAnswer.from(status: 0, stdout: "true\n", stderr: "", path: path) == .repository)
        #expect(GitRepositoryAnswer.from(status: 0, stdout: "false\n", stderr: "", path: path) == .notARepository)
        let outside = GitRepositoryAnswer.from(
            status: 128, stdout: "",
            stderr: "fatal: not a git repository (or any of the parent directories): .git\n",
            path: path
        )
        #expect(outside == .notARepository)
    }

    /// What Apple's `/usr/bin/git` prints on a Mac without the command line tools.
    @Test("the git stub with no developer tools is git not running")
    func stubWithoutDeveloperTools() {
        let stderr = """
            xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), \
            missing xcrun at: /Library/Developer/CommandLineTools/usr/bin/xcrun

            """
        let answer = GitRepositoryAnswer.from(status: 1, stdout: "", stderr: stderr, path: path)
        guard case .problem(.gitUnusable(let detail)) = answer else {
            Issue.record("expected git unusable, got \(answer)")
            return
        }
        #expect(detail.hasPrefix("xcrun: error: invalid active developer path"))
        #expect(GitRepositoryProblem.gitUnusable(detail: detail).sentence.contains("xcode-select --install"))
    }

    @Test("a repository owned by someone else names the folder to trust")
    func dubiousOwnership() {
        let stderr = """
            fatal: detected dubious ownership in repository at '/Volumes/Work/thing'
            To add an exception for this directory, call:

            \tgit config --global --add safe.directory /Volumes/Work/thing

            """
        let answer = GitRepositoryAnswer.from(status: 128, stdout: "", stderr: stderr, path: path + "/src")
        #expect(answer == .problem(.unsafeOwnership(path: "/Volumes/Work/thing")))
        let sentence = GitRepositoryProblem.unsafeOwnership(path: "/Volumes/Work/thing").sentence
        #expect(sentence.contains("safe.directory '/Volumes/Work/thing'"))
    }

    @Test("anything else keeps git's first line")
    func otherFailure() {
        let answer = GitRepositoryAnswer.from(
            status: 128, stdout: "", stderr: "\nfatal: bad config line 3 in file .git/config\nmore\n", path: path
        )
        #expect(answer == .problem(.failed(detail: "fatal: bad config line 3 in file .git/config")))
    }

    @Test("a git that cannot be found is not a folder that is not a repository")
    func launchFailure() {
        let missing = ShellError(command: "git", status: 127, stderr: "git not found on PATH")
        #expect(GitRepositoryAnswer.from(launchFailure: missing) == .problem(.gitUnusable(detail: "git not found on PATH")))
    }

    /// The real refusal, from the real git, through the path `WorkspaceManager.addRepository` takes.
    /// `GIT_TEST_ASSUME_DIFFERENT_OWNER` is git's own hook for producing it without a second account.
    ///
    /// Without the machine's own git config, because a `safe.directory = *` in it switches the
    /// check off and git answers that the folder is a repository. This passed on a Mac and failed on
    /// every push to main with exactly that answer, and pointing `GIT_CONFIG_GLOBAL` at a file
    /// holding the line reproduces it locally.
    @Test("git's own ownership refusal is read as one", .tags(.git), .scratchDirectory)
    func realOwnershipRefusal() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        #expect(await Git.repositoryAnswer(repo.path) == .repository)
        let refused = await Git.repositoryAnswer(repo.path, environment: [
            "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        ])
        guard case .problem(.unsafeOwnership(let trusted)) = refused else {
            Issue.record("expected an ownership refusal, got \(refused)")
            return
        }
        #expect(trusted.hasSuffix(URL(fileURLWithPath: repo.path).lastPathComponent))
    }
}

@Suite("Folder verdict when git will not answer")
struct FolderVerdictGitProblemTests {
    private let problem = GitRepositoryProblem.gitUnusable(detail: "xcrun: error")

    private func facts(isRepository: Bool) -> FolderFacts {
        FolderFacts(
            path: "/Users/tester/dev/thing",
            isRepository: isRepository,
            homeDirectory: "/Users/tester",
            workspacesRoot: "/Users/tester/bloom/workspaces",
            gitProblem: problem
        )
    }

    /// Offering would be `git init`: failing on a git that does not run, or reinitialising a
    /// repository git merely refused to read.
    @Test("a folder git could not read is refused, not offered")
    func refusedNotOffered() {
        #expect(FolderVerdict.of(facts(isRepository: false)) == .refuse(.gitCannotRead(problem)))
        #expect(FolderRefusal.gitCannotRead(problem).sentence == problem.sentence)
    }

    @Test("an agent is told not to work around it")
    func agentSentence() {
        let ownership = FolderRefusal.gitCannotRead(.unsafeOwnership(path: "/Volumes/Work/thing"))
        #expect(ownership.agentSentence.contains("do not change git's safe.directory setting yourself"))
    }

    /// The sheet's `.git` on disk is not git agreeing. Once git has been asked and refused, the
    /// button that said Add Project is held, with the reason under the field.
    @Test("the start sheet refuses a .git that git will not read")
    func startSheetRefuses() {
        var typed = NewProjectFacts(
            name: "thing",
            location: "/Users/tester/dev",
            path: "/Users/tester/dev/thing",
            locationExists: true,
            targetExists: true,
            targetIsDirectory: true,
            targetIsRepository: true,
            nearestExistingAncestor: "/Users/tester/dev",
            homeDirectory: "/Users/tester",
            workspacesRoot: "/Users/tester/bloom/workspaces"
        )
        #expect(ProjectTargetVerdict.of(typed) == .add(root: "/Users/tester/dev/thing"))

        typed.gitProblem = problem
        let verdict = ProjectTargetVerdict.of(typed)
        #expect(verdict == .refuse(.folder(.gitCannotRead(problem))))
        #expect(!verdict.isAllowed)
    }

    @Test("adding through the manager says why git refused")
    func workspaceErrorSaysWhy() {
        let error = WorkspaceError.gitCannotRead(.unsafeOwnership(path: "/Volumes/Work/thing"))
        #expect(error.readableMessage.contains("belongs to a different user account"))
    }
}

@Suite("Setup probe reading git --version")
struct SetupProbeGitTests {
    @Test("a git that exits non-zero is not installed")
    func failingVersionIsMissing() {
        let stub = ShellResult(status: 1, stdout: "", stderr: "xcrun: error: invalid active developer path")
        #expect(SetupProbe.gitOutcome(version: stub) == .missing)
    }

    @Test("a working git is ready with its version")
    func workingVersion() {
        let git = ShellResult(status: 0, stdout: "git version 2.50.1 (Apple Git-155)\n", stderr: "")
        #expect(SetupProbe.gitOutcome(version: git).isReady)
    }

    @Test("a check that learnt nothing does not call git missing")
    func noAnswer() {
        #expect(SetupProbe.gitOutcome(version: nil) == .ready(detail: nil))
    }
}
