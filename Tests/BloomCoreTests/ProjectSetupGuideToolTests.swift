import Foundation
import Testing
@testable import BloomCore

@Suite("Project setup guide for agents")
struct ProjectSetupGuideToolTests {
    @Test("workspace and owner agents can discover the guide without an approval prompt")
    func discoverable() {
        #expect(BridgeToolbox.standard.tools(for: .workspace).contains { $0.name == "project_setup_guide" })
        #expect(BridgeToolbox.standard.tools(for: .owner).contains { $0.name == "project_setup_guide" })
        #expect(BridgeToolApproval.isSelfApproved(toolName: BridgeToolApproval.toolPrefix + "project_setup_guide"))
    }

    @Test("the guide separates repository settings from this app's current mail port")
    func currentMailSettings() async throws {
        let store = try makeTestStore("project-setup-guide")
        let tool = ProjectSetupGuideTool(mailSettings: { .init(isEnabled: true, smtpPort: 1039) })
        let result = await tool.call(
            MCPRequest(id: .integer(1), method: "project_setup_guide"), as: .owner, store: store
        )

        #expect(!result.isError)
        #expect(result.text.contains(".bloom/settings.toml"))
        #expect(result.text.contains(".bloom/settings.local.toml"))
        #expect(result.text.contains("setup_file = \".bloom/setup.sh\""))
        #expect(result.text.contains("[scripts.run.dev]"))
        #expect(result.text.contains("url = \"http://localhost:$BLOOM_PORT\""))
        #expect(result.text.contains("SMTP host 127.0.0.1, port 1039"))
        #expect(result.text.contains("Do not invent a mail table in settings.toml"))
        #expect(result.text.contains("mail_list and mail_read"))
    }

    @Test("an off inbox is called out before an agent configures the project")
    func disabledMail() {
        let guide = ProjectSetupGuideTool.guide(mail: .init(isEnabled: false, smtpPort: 2256))
        #expect(guide.contains("Incoming mails is off"))
        #expect(guide.contains("port 2256"))
    }
}
