import Foundation
import Testing
@testable import BloomCore

/// Turning a dead agent process into a sentence.
///
/// The case this exists for is recorded below: the Claude Code CLI died inside its own bundle and
/// wrote a Node crash dump to stderr, whose second line is the minified source line the fault
/// landed on. That line was twenty five thousand characters long, and the transcript drew it as
/// the error message. Everything here is measured against that row staying one readable line while
/// the whole dump stays reachable underneath it.
@Suite("Agent exits")
struct AgentExitTests {
    // MARK: The recorded crash

    /// The dump from the recorded row, rebuilt line for line.
    ///
    /// The bundle line is the only part not reproduced character for character: it is a slice of
    /// somebody else's program, so a short piece of it is repeated up to the length the real one
    /// had. Nothing in the reading looks at its contents, only at how long it is and where it sits.
    static let nodeCrash: String = {
        let bundlePrefix = "`),Q.code=Z.error.code,Q.errors=Z.error.errors;else Q.message=Z.error.message,"
            + "Q.code=Z.error.code;else if(B&&B.status>=400)Q.message=Z,Q.status=B.status;return Q}}"
            + "Cn2.DefaultTransporter=p31;p31.USER_AGENT=`${Dn2}/${uE6.version}`});var et=U((rV0,$n2)=>"
            + "{/*! safe-buffer. MIT License. Feross Aboukhadijeh <https://feross.org/opensource> */"
            + "var yj1=X1(\"buffer\"),DM=yj1.Buffer;function En2(A,B){for(var Q in A)B[Q]=A[Q]}"
        var bundle = bundlePrefix
        while bundle.count < 25_720 { bundle += bundlePrefix }
        bundle = String(bundle.prefix(25_720))

        return """
        file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:489
        \(bundle)
        \(String(repeating: " ", count: 1_020))

        TypeError: Cannot read properties of undefined (reading 'prototype')
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:489:25504
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:10:402
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:489:25624
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:10:402
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:491:3218
            at file:///opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js:10:402

        Node.js v25.4.0
        """
    }()

    static func payload(status: Int, stderr: String, command: String = "") -> Data {
        var object: [String: Any] = [
            "type": "error",
            "subtype": "process_exit",
            "status": status,
            "stderr": stderr,
        ]
        if !command.isEmpty { object["command"] = command }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("the row a bundled CLI's crash produces is one sentence")
    func nodeCrashStaysASentence() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: Self.nodeCrash))

        #expect(exit.cause == .crashed("TypeError: Cannot read properties of undefined (reading 'prototype')"))
        #expect(exit.title == "Agent exited (1)")
        #expect(exit.summary == "The CLI crashed: TypeError: Cannot read properties of undefined (reading 'prototype').")
        #expect(!exit.summary.contains("\n"))
        #expect(exit.summary.count <= AgentExit.summaryLimit + 1)
        // The bundle is the thing that must not reach a row, by any route.
        #expect(!exit.summary.contains("safe-buffer"))
        #expect(!exit.summary.contains("DefaultTransporter"))
    }

    @Test("the crash dump is kept whole behind the row")
    func nodeCrashKeepsItsDetail() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: Self.nodeCrash))

        #expect(exit.detail == Self.nodeCrash)
        #expect(exit.hasDetail)
        #expect(exit.detail.contains("Node.js v25.4.0"))
    }

    @Test("a crash says the work survived and what to try")
    func nodeCrashAdvises() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: Self.nodeCrash))

        #expect(exit.advice.contains("still in the worktree"))
        #expect(exit.advice.contains("send the turn again"))
    }

    @Test("the row names the binary that died, because a name is not a file")
    func crashNamesTheBinary() {
        let exit = AgentExit.decode(Self.payload(
            status: 1,
            stderr: Self.nodeCrash,
            command: "/opt/homebrew/bin/claude"
        ))

        #expect(exit.command == "/opt/homebrew/bin/claude")
        #expect(exit.advice.hasSuffix("Bloom ran /opt/homebrew/bin/claude."))
        // Still one line, whatever was appended to the advice under it.
        #expect(!exit.summary.contains("claude.js"))
    }

    @Test("a payload from before the command was recorded says nothing about it")
    func advicePredatingTheCommandField() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: Self.nodeCrash))

        #expect(exit.command.isEmpty)
        #expect(!exit.advice.contains("Bloom ran"))
    }

    // MARK: Real errors, short ones especially

    @Test("a short error is shown as it was written")
    func shortErrorIsVerbatim() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: "Error: connection closed by the server\n"))

        #expect(exit.cause == .reported("Error: connection closed by the server"))
        #expect(exit.summary == "Error: connection closed by the server")
    }

    @Test("a short error of several lines keeps all of them, folded onto one")
    func shortMultilineErrorIsKept() {
        let stderr = "Cannot connect to the API.\nCheck your network.\nrequest_id: abc123"
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.summary == "Cannot connect to the API. Check your network. request_id: abc123")
    }

    @Test("a long error is reduced to its first readable line, not to its first characters")
    func longErrorTakesItsFirstLine() {
        let stderr = """
        API Error: 500 Internal Server Error
        \(String(repeating: "x", count: 5_000))
        """
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.summary == "API Error: 500 Internal Server Error")
    }

    @Test("output with no readable line in it still says something true")
    func unreadableOutputSaysSomething() {
        let stderr = String(repeating: "q", count: 9_000)
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.summary.count <= AgentExit.summaryLimit + 1)
        #expect(!exit.summary.contains("qqqqqqqqqq"))
        #expect(exit.detail == stderr)
    }

    // MARK: The other ways a run ends

    @Test("a process that printed nothing still gets a sentence and a next step")
    func silentExit() {
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: ""))

        #expect(exit.cause == .silent)
        #expect(exit.summary == "It stopped without printing anything.")
        #expect(!exit.advice.isEmpty)
        #expect(!exit.hasDetail)
    }

    @Test("a missing CLI is named as missing rather than as a crash")
    func missingExecutable() {
        let stderr = "`claude` exited 127: claude not found on PATH"
        let exit = AgentExit.decode(Self.payload(status: 127, stderr: stderr))

        #expect(exit.cause == .missing)
        #expect(exit.advice.contains("Install"))
    }

    @Test("a status of 127 from the agent itself is not read as a missing CLI")
    func statusOneTwentySevenFromTheAgent() {
        let exit = AgentExit.decode(Self.payload(status: 127, stderr: "Error: the model refused the request"))

        #expect(exit.cause == .reported("Error: the model refused the request"))
    }

    @Test("a failed write is Bloom's failure, and says so")
    func storageFailure() {
        let object: [String: Any] = [
            "type": "error",
            "subtype": "storage",
            "message": "storing an event: database is locked",
        ]
        let exit = AgentExit.decode(try! JSONSerialization.data(withJSONObject: object))

        #expect(exit.cause == .storage("storing an event: database is locked"))
        #expect(exit.title == "Not saved")
        #expect(exit.advice.contains("Bloom's copy"))
    }

    @Test("a payload that is not JSON at all still draws a row")
    func unreadablePayload() {
        let exit = AgentExit.decode(Data("not json".utf8))

        #expect(exit.cause == .silent)
        #expect(!exit.summary.isEmpty)
        #expect(!exit.advice.isEmpty)
    }

    // MARK: Shapes

    @Test("indented output that is not a stack is not read as a crash")
    func indentedOutputIsNotAStack() {
        let stderr = """
        Running checks
          at the top level
          at the second level
        """
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.cause == .reported("Running checks at the top level at the second level"))
    }

    @Test("a stack whose error line is missing falls back rather than inventing one")
    func stackWithoutAnErrorLine() {
        let stderr = """
            at one (/a.js:1:1)
            at two (/b.js:2:2)
        """
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        if case .crashed = exit.cause { Issue.record("read a stack with no error line as a crash") }
    }

    @Test("a crash whose source line is short is read the same way")
    func plainScriptCrash() {
        let stderr = """
        /Users/someone/script.js:3
          throw new Error("boom")
          ^

        Error: boom
            at Object.<anonymous> (/Users/someone/script.js:3:9)

        Node.js v22.19.0
        """
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.cause == .crashed("Error: boom"))
    }

    @Test("colour codes are taken out of the sentence and left in the detail")
    func escapesAreStripped() {
        let stderr = "\u{1B}[31mError: the request timed out\u{1B}[0m"
        let exit = AgentExit.decode(Self.payload(status: 1, stderr: stderr))

        #expect(exit.summary == "Error: the request timed out")
        #expect(exit.detail == stderr)
    }

    @Test("every ending has something to do next")
    func everyCauseAdvises() {
        let causes: [AgentExitCause] = [
            .crashed("TypeError: x"),
            .missing,
            .reported("Error: x"),
            .silent,
            .storage("storing an event: disk full"),
            .notStarted("Bloom could not open an agent for this chat."),
        ]

        for cause in causes {
            let exit = AgentExit(status: 1, cause: cause, detail: "")
            #expect(!exit.advice.isEmpty)
            #expect(exit.advice.hasSuffix("."))
            #expect(!exit.summary.isEmpty)
            #expect(!exit.summary.contains("\n"))
        }
    }
}
