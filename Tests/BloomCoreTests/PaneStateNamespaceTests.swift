import Foundation
import Testing
@testable import BloomCore

@Suite struct PaneStateNamespaceTests {
    @Test func copiedWorkspaceDatabasesAndDifferentAccountsHaveSeparateOrigins() {
        let first = PaneStateNamespace.connectionID(.ssh(host: "bloom@server-a", executable: "/opt/server", directory: "/data/one"))
        let variants: [ServerEndpoint] = [
            .ssh(host: "bloom@server-b", executable: "/opt/server", directory: "/data/one"),
            .ssh(host: "other@server-a", executable: "/opt/server", directory: "/data/one"),
            .ssh(host: "bloom@server-a", executable: "/opt/server", directory: "/data/copy"),
            .local(directory: "/data/one"),
        ]
        #expect(variants.allSatisfy { PaneStateNamespace.connectionID($0) != first })
        #expect(PaneStateNamespace.connectionID(.ssh(host: "bloom@server-a", executable: "/opt/new-server", directory: "/data/one", identityFile: "/new/key")) == first)
    }

    @Test func browserOriginsNormalizeCredentialsAndDefaultPortWithoutPersistingThem() {
        let ordinary = PaneStateNamespace.connectionID(.https(url: "https://server.example/"))
        #expect(PaneStateNamespace.connectionID(.https(url: "https://SERVER.example:443/")) == ordinary)
        #expect(PaneStateNamespace.connectionID(.https(url: "https://user:secret@server.example/?token=private")) == ordinary)
        #expect(!ordinary.contains("secret"))
    }

    @Test func identicalTabKeysCannotReadOrOverwriteAnotherServerDomain() throws {
        let domain = "bloom-pane-test-" + UUID().uuidString
        let names = [domain, PaneStateNamespace.suiteName(connectionID: "server-a", appDomain: domain),
                     PaneStateNamespace.suiteName(connectionID: "server-b", appDomain: domain)]
        let defaults = try names.map { try #require(UserDefaults(suiteName: $0)) }
        defer { for (name, store) in zip(names, defaults) { store.removePersistentDomain(forName: name) } }
        let key = TabDefaults.tabListKey(WorkspaceID("copied-id"))
        defaults[0].set(Data("local".utf8), forKey: key)
        #expect(defaults[1].data(forKey: key) == nil)
        #expect(defaults[2].data(forKey: key) == nil)
        defaults[1].set(Data("remote-a".utf8), forKey: key)
        defaults[2].set(Data("remote-b".utf8), forKey: key)
        defaults[1].removeObject(forKey: key)
        #expect(defaults[0].data(forKey: key) == Data("local".utf8))
        #expect(defaults[2].data(forKey: key) == Data("remote-b".utf8))
    }
}
