import Testing
@testable import BloomCore

@Suite("File tree change highlights")
struct FileTreeChangesTests {
    @Test("A changed file highlights every folder leading to it")
    func nestedFile() {
        let paths = FileTreeChanges.highlightedPaths(for: [
            "resources/views/components/ai-chat/panel.blade.php",
        ])
        #expect(paths == [
            "resources", "resources/views", "resources/views/components",
            "resources/views/components/ai-chat",
            "resources/views/components/ai-chat/panel.blade.php",
        ])
    }

    @Test("Multiple changes share ancestors without highlighting siblings or similar prefixes")
    func multipleChanges() {
        let paths = FileTreeChanges.highlightedPaths(for: [
            "app/view/a.swift", "app/view/b.swift", "README.md",
        ])
        #expect(paths == ["app", "app/view", "app/view/a.swift", "app/view/b.swift", "README.md"])
        #expect(!paths.contains("app/views"))
        #expect(!paths.contains("app/view/c.swift"))
        #expect(!paths.contains(""))
    }

    @Test("Refreshing after changes clear leaves no highlighted paths")
    func clearedChanges() {
        #expect(FileTreeChanges.highlightedPaths(for: []).isEmpty)
        #expect(FileTreeChanges.highlightedPaths(for: [""]).isEmpty)
    }
}
