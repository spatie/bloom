import Foundation
import Testing
@testable import BloomCore

/// Links to a workspace or chat written in a chat. They navigate and do nothing else, which is
/// what lets a transcript draw them at all: everything else in Bloom's own schemes stays text.
/// The test host registers no URL types, so this copy's scheme is `bloom` throughout. See
/// `WorkspaceLink`.
@Suite("Workspace links in chat")
struct WorkspaceLinkTests {
    @Test("a workspace or chat link in this copy's scheme is one, a prompt link or another copy's is not")
    func whichLinks() throws {
        let workspace = try #require(URL(string: "bloom://workspace/w1"))
        let chat = try #require(URL(string: "BLOOM://workspace/w1?chat=c1"))
        #expect(WorkspaceLink(workspace, schemes: ["bloom"]) == WorkspaceLink(workspace, schemes: ["bloom"]))
        #expect(WorkspaceLink(workspace, schemes: ["bloom"])?.workspaceID == WorkspaceID("w1"))
        #expect(WorkspaceLink(workspace, schemes: ["bloom"])?.chatID == nil)
        #expect(WorkspaceLink(chat, schemes: ["bloom"])?.chatID == SessionID("c1"))

        for refused in [
            "bloom://?prompt=fix&path=/tmp", "bloom://prompt=fix&path=/tmp", "bloom://workspace/",
            "bloom://workspace/w1/extra", "bloom://workspace/w1#c1", "bloom://open",
        ] {
            let url = try #require(URL(string: refused))
            #expect(WorkspaceLink(url, schemes: ["bloom"]) == nil, "\(refused)")
        }
        #expect(WorkspaceLink(workspace, schemes: ["bloomdev"]) == nil)
    }

    @Test("the address the bridge hands out reads back as the same workspace and chat")
    func addressRoundTrips() throws {
        for (workspace, chat) in [("w1", nil), ("w1", "c1"), ("w1", "c+2"), ("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "a b")] {
            let address = WorkspaceLink.address(
                workspace: WorkspaceID(workspace), chat: chat.map(SessionID.init), scheme: "bloomdev"
            )
            let url = try #require(URL(string: address))
            let link = try #require(WorkspaceLink(url, schemes: ["bloomdev"]))
            #expect(link.workspaceID == WorkspaceID(workspace))
            #expect(link.chatID == chat.map(SessionID.init))
        }
        #expect(WorkspaceLink.address(workspace: WorkspaceID("w1"), chat: SessionID("c1"), scheme: "bloom")
            == "bloom://workspace/w1?chat=c1")
    }

    @Test("this copy's scheme is read off its bundle, and a link it writes prefers the shipped one")
    func schemes() {
        let dev: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["BloomDev"]]]]
        #expect(BloomURLScheme.registered(in: dev) == ["bloomdev"])
        #expect(BloomURLScheme.registered(in: nil) == ["bloom"])
        #expect(BloomURLScheme.primary(of: ["bloomdev"]) == "bloomdev")
        #expect(BloomURLScheme.primary(of: ["bloomdev", "bloom"]) == "bloom")
    }

    @Test("the transcript opens workspace links without them being allowed, and nothing else of Bloom's")
    func policy() throws {
        let link = try #require(URL(string: "bloom://workspace/w1?chat=c1"))
        let prompt = try #require(URL(string: "bloom://?prompt=fix&path=/tmp"))
        #expect(LinkPolicy.opens(link))
        #expect(!LinkPolicy.opens(link, ownSchemes: ["bloomdev"]))
        #expect(!LinkPolicy.opens(prompt))
        #expect(!LinkPolicy.opens(prompt, allowedSchemes: ["bloom"]))
    }

    @Test("a workspace link written as text is found, without the sentence's punctuation")
    func scanning() {
        let text = "Started it: bloom://workspace/w1?chat=c1. See (bloom://workspace/w2) too."
        #expect(LinkScan.links(in: text).map(\.url) == ["bloom://workspace/w1?chat=c1", "bloom://workspace/w2"])
        #expect(LinkScan.links(in: "Run bloom://?prompt=fix&path=/tmp now").isEmpty)
        #expect(LinkScan.links(in: "`bloom://workspace/w1`").isEmpty)
        #expect(LinkScan.links(in: "notbloom://workspace/w1").isEmpty)
    }

    @Test("its menu opens it in Bloom and offers no browser")
    func menu() throws {
        let chat = try #require(URL(string: "bloom://workspace/w1?chat=c1"))
        let workspace = try #require(URL(string: "bloom://workspace/w1"))
        #expect(TranscriptLinkMenu.items(for: chat, placement: .pane)
            == [TranscriptLinkItem(title: "Open Chat", target: .bloom)])
        #expect(TranscriptLinkMenu.items(for: workspace, placement: .detached).map(\.title) == ["Open Workspace"])
    }

    @Test("typing bloom into the allowed schemes says the links already work")
    func settingsNote() {
        #expect(TranscriptLinkPreferences.ignoredNote(["file"]) == "Ignored schemes: file.")
        let note = TranscriptLinkPreferences.ignoredNote(["bloom"])
        #expect(note.hasPrefix("Ignored schemes: bloom. Links to Bloom workspaces and chats open"))
        #expect(note.contains("bloom://workspace/<id>?chat=<id>"))
    }
}
