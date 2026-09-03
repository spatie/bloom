import Testing
@testable import BloomCore

@Suite("Executable search path")
struct ExecutableSearchPathTests {
    @Test("includes stable package-manager and shim directories")
    func includesStableDirectories() {
        let home = "/Users/example"
        let paths = ExecutableSearchPath.additionalDirectories(home: home, childrenOf: { _ in [] })

        #expect(paths.contains("\(home)/.local/bin"))
        #expect(paths.contains("\(home)/.local/share/mise/shims"))
        #expect(paths.contains("\(home)/.asdf/shims"))
        #expect(paths.contains("\(home)/Library/pnpm"))
    }

    @Test("finds every installed nvm version with the newest first")
    func findsNVMVersions() {
        let home = "/Users/example"
        let root = "\(home)/.nvm/versions/node"
        let paths = ExecutableSearchPath.additionalDirectories(home: home) { path in
            path == root ? ["v9.11.2", "v22.18.0", "v20.19.4"] : []
        }

        let found = paths.filter { $0.hasPrefix(root) }
        #expect(found == [
            "\(root)/v22.18.0/bin",
            "\(root)/v20.19.4/bin",
            "\(root)/v9.11.2/bin",
        ])
    }

    @Test("finds both fnm data locations")
    func findsFNMVersions() {
        let home = "/Users/example"
        let library = "\(home)/Library/Application Support/fnm/node-versions"
        let local = "\(home)/.local/share/fnm/node-versions"
        let paths = ExecutableSearchPath.additionalDirectories(home: home) { path in
            switch path {
            case library: ["v22.18.0"]
            case local: ["v20.19.4"]
            default: []
            }
        }

        #expect(paths.contains("\(library)/v22.18.0/installation/bin"))
        #expect(paths.contains("\(local)/v20.19.4/installation/bin"))
    }
}
