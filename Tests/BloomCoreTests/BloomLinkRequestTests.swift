import Foundation
import Testing
@testable import BloomCore

@Suite("Bloom deep links")
struct BloomLinkRequestTests {
    @Test("workspace and optional chat IDs are decoded once")
    func workspaceLinks() throws {
        let plain = try #require(URL(string: "bloom://workspace/w1"))
        #expect(try BloomLinkRequest(url: plain, schemes: ["bloom"]) == .workspace(WorkspaceID("w1"), chatID: nil))
        let chat = try #require(URL(string: "bloom://workspace/w%2520?chat=c%2B2"))
        #expect(try BloomLinkRequest(url: chat, schemes: ["bloom"]) == .workspace(
            WorkspaceID("w%20"), chatID: SessionID("c+2")
        ))
    }

    @Test("development links only work in a copy registering the development scheme")
    func schemeIsolation() throws {
        let dev = try #require(URL(string: "bloomdev://workspace/w1?chat=c1"))
        let production = try #require(URL(string: "bloom://workspace/w1"))
        #expect(throws: BloomLinkRequest.Failure.unsupportedScheme) {
            try BloomLinkRequest(url: dev, schemes: ["bloom"])
        }
        #expect(throws: BloomLinkRequest.Failure.unsupportedScheme) {
            try BloomLinkRequest(url: production, schemes: ["bloomdev"])
        }
        #expect(try BloomLinkRequest(url: dev, schemes: ["bloomdev"]) == .workspace(
            WorkspaceID("w1"), chatID: SessionID("c1")
        ))
    }

    @Test("malformed workspace links never fall through to creating work", arguments: [
        "bloom://workspace", "bloom://workspace/", "bloom://workspace/w1/extra",
        "bloom://workspace/w1/", "bloom://workspace/w%2F1", "bloom://workspace/%20",
        "bloom://workspace/w1?chat=", "bloom://workspace/w1?chat", "bloom://workspace/w1?chat=%20",
        "bloom://workspace/w1?chat=c1&chat=c2", "bloom://workspace:42/w1", "bloom://workspace/w1#c1",
    ])
    func malformedWorkspace(argument: String) throws {
        let url = try #require(URL(string: argument))
        #expect(throws: BloomLinkRequest.Failure.invalidWorkspace) {
            try BloomLinkRequest(url: url, schemes: ["bloom"])
        }
    }

    @Test("both prompt link forms preserve form decoding", arguments: ["", "?"])
    func promptLinks(prefix: String) throws {
        let url = try #require(URL(string: "bloom://\(prefix)prompt=fix+%2B+%2520&path=%2Ftmp%2Ftwo+words"))
        #expect(try BloomLinkRequest(url: url, schemes: ["bloom"]) == .prompt(
            prompt: "fix + %20", path: "/tmp/two words"
        ))
    }

    @Test("prompt links still require both nonempty fields", arguments: [
        "bloom://?prompt=fix", "bloom://?path=/tmp", "bloom://?prompt=&path=/tmp",
    ])
    func incompletePrompt(argument: String) throws {
        let url = try #require(URL(string: argument))
        #expect(throws: BloomLinkRequest.Failure.missingPromptAndPath) {
            try BloomLinkRequest(url: url, schemes: ["bloom"])
        }
    }
}
