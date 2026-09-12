import Testing
@testable import BloomClient

@Suite("Approval transport recovery")
struct RemoteApprovalSubmissionTests {
    @Test("A decision retries on a new connection using its exact original ID and answers")
    func freshTransportSameDecision() async throws {
        let command = RemoteCommand.call("answer", ["requestID": .string("permission-1"),
                                                   "answer": .object(["allowOnce": .object([:])])])
        let submission = try RemoteApprovalSubmission(command: command, origin: "https://bloom.example")
        let lost = ApprovalClient(acknowledge: false)
        do { try await submission.submit(using: lost, origin: "https://bloom.example"); Issue.record("Expected lost acknowledgement") } catch {
            #expect(error is ConnectionFailure)
        }
        let restored = ApprovalClient(acknowledge: true)
        try await submission.submit(using: restored, origin: "https://BLOOM.example:443/")
        let first = await lost.commands, retry = await restored.commands
        #expect(first == [command])
        #expect(retry == [command])
    }

    @Test("Changing the selected server cannot redirect a pending decision")
    func rejectsAnotherOrigin() async throws {
        let submission = try RemoteApprovalSubmission(command: .call("answer"), origin: "ssh://bloom@server:22/data/first")
        let other = ApprovalClient(acknowledge: true)
        do {
            try await submission.submit(using: other, origin: "ssh://bloom@server/data/second")
            Issue.record("Expected origin refusal")
        } catch { #expect(error is ConnectionFailure) }
        let sent = await other.commands
        #expect(sent.isEmpty)
    }
}

private actor ApprovalClient: RemoteRequesting {
    let acknowledge: Bool
    private(set) var commands: [RemoteCommand] = []
    init(acknowledge: Bool) { self.acknowledge = acknowledge }
    func request(_ command: RemoteCommand) throws -> JSONValue {
        commands.append(command)
        if !acknowledge { throw ConnectionFailure("The connection closed before acknowledgement") }
        return .object(["accepted": .object([:])])
    }
}
