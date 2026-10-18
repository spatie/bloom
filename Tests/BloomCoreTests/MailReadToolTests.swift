import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import BloomCore

@Suite("Reading Bloom's captured mail")
@MainActor
struct MailReadToolTests {
    @Test("both roles can discover the inbox readers")
    func discoverable() {
        let fixture = MailFixture()
        let toolbox = BridgeToolbox(handlers: [
            MailListTool(client: { fixture.client }),
            MailReadTool(client: { fixture.client }),
        ])
        for role in [BridgeRole.workspace, .owner] {
            #expect(toolbox.tools(for: role).map(\.name).contains("mail_list"))
            #expect(toolbox.tools(for: role).map(\.name).contains("mail_read"))
        }
        #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + "mail_list"))
        #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + "mail_read"))
    }

    @Test("listing reports mailbox totals and a cursor through searched summaries")
    func listsPage() async throws {
        let fixture = MailFixture()
        let store = try makeTestStore("mail-read-list")
        let tool = MailListTool(client: { fixture.client })
        let result = await tool.call(
            request("mail_list", ["query": .string("subject:welcome"), "limit": .integer(1)]),
            as: .owner, store: store
        )
        #expect(!result.isError)
        let fields = parsed(result)
        #expect(fields["total"] == .integer(2))
        #expect(fields["unread"] == .integer(1))
        #expect(fields["matching"] == .integer(2))
        #expect(fields["next_start"] == .integer(1))
        guard case .array(let messages)? = fields["messages"],
              case .object(let first)? = messages.first else {
            Issue.record("mail_list did not return message summaries")
            return
        }
        #expect(first["id"] == .string("m1"))
        #expect(first["read"] == .bool(false))
        let url = try #require(fixture.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/v1/search")
        #expect(components.queryItems?.first { $0.name == "query" }?.value == "subject:welcome")
        #expect(components.queryItems?.first { $0.name == "limit" }?.value == "1")
    }

    @Test("reading pages through text and can inspect HTML separately")
    func readsParts() async throws {
        let fixture = MailFixture()
        let store = try makeTestStore("mail-read-parts")
        let tool = MailReadTool(client: { fixture.client })
        let first = await tool.call(request("mail_read", ["id": .string("m1")]), as: workspaceIdentity, store: store)
        #expect(!first.isError)
        let firstFields = parsed(first)
        #expect(firstFields["subject"] == .string("Welcome"))
        #expect(firstFields["part"] == .string("text"))
        #expect(firstFields["next_offset"] == .integer(20_000))
        #expect(firstFields["body"] == .string(String(repeating: "A", count: 20_000)))
        guard case .array(let attachments)? = firstFields["attachments"],
              case .object(let attachment)? = attachments.first else {
            Issue.record("mail_read did not return attachment metadata")
            return
        }
        #expect(attachment["file_name"] == .string("invoice.pdf"))

        let rest = await tool.call(
            request("mail_read", ["id": .string("m1"), "offset": .integer(20_000)]),
            as: workspaceIdentity, store: store
        )
        #expect(parsed(rest)["body"] == .string("AAAAAAAAAA"))
        #expect(parsed(rest)["next_offset"] == .null)

        let html = await tool.call(
            request("mail_read", ["id": .string("m1"), "part": .string("html")]),
            as: workspaceIdentity, store: store
        )
        #expect(parsed(html)["body"] == .string("<p>Welcome</p>"))
    }

    @Test("disabled inbox and malformed IDs fail without contacting Mailpit")
    func unavailableAndInvalid() async throws {
        let fixture = MailFixture()
        let store = try makeTestStore("mail-read-invalid")
        let unavailable = await MailListTool(client: { nil }).call(
            request("mail_list", [:]), as: .owner, store: store
        )
        #expect(unavailable.isError)
        #expect(unavailable.text.contains("Enable Incoming mails"))
        let invalid = await MailReadTool(client: { fixture.client }).call(
            request("mail_read", ["id": .string("../messages")]), as: .owner, store: store
        )
        #expect(invalid.isError)
        #expect(fixture.requests.isEmpty)
    }

    private func request(_ method: String, _ params: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .integer(1), method: method, params: .object(params))
    }

    private var workspaceIdentity: BridgeIdentity {
        BridgeIdentity(sessionID: SessionID("mail-reader"), workspaceID: WorkspaceID("mail-workspace"), role: .workspace)
    }

    private func parsed(_ result: BridgeToolResult) -> [String: JSONValue] {
        guard let json = JSONValue.parse(result.text), case .object(let fields) = json else {
            Issue.record("not a JSON object: \(result.text)")
            return [:]
        }
        return fields
    }

    private final class MailFixture: Sendable {
        private let asked = Mutex<[URLRequest]>([])

        var requests: [URLRequest] { asked.withLock { $0 } }

        var client: MailpitClient {
            MailpitClient(base: URL(string: "http://127.0.0.1:8026")!) { [self] request in
                asked.withLock { $0.append(request) }
                let body = request.url?.path.contains("/api/v1/message/") == true
                    ? Self.message : Self.page
                return (Data(body.utf8), 200)
            }
        }

        private static let page = """
            {"total":2,"unread":1,"messages_count":2,"start":0,"messages":[
              {"ID":"m1","Read":false,"From":{"Name":"Example","Address":"sender@example.test"},
               "To":[{"Address":"inbox@example.test"}],"Subject":"Welcome",
               "Created":"2026-10-18T12:00:00Z","Attachments":1,"Snippet":"Hello"}
            ]}
            """

        private static let message = """
            {"ID":"m1","From":{"Name":"Example","Address":"sender@example.test"},
             "To":[{"Address":"inbox@example.test"}],"Subject":"Welcome",
             "Date":"2026-10-18T12:00:00Z","Text":"\(String(repeating: "A", count: 20_010))",
             "HTML":"<p>Welcome</p>","Attachments":[
               {"PartID":"2","FileName":"invoice.pdf","ContentType":"application/pdf","Size":5120}
             ]}
            """
    }
}
