import Testing
import Foundation
@testable import BloomCore

/// The rule that decides whether a tool argument is drawn as a file or as code.
///
/// It is worth pinning down from both ends. A file that loses its icon is a chip that looks like
/// it did yesterday; a command that gains one is the transcript telling the reader something
/// untrue about what the agent did. So the rejections below matter more than the acceptances, and
/// the ones that reject real files are listed as such rather than left to be discovered as bugs.
@Suite("File path guess")
struct FilePathGuessTests {
    // MARK: - What is a file

    @Test("a name with an extension is a file", arguments: [
        "HarbourMap.php",
        "lights.yml",
        "Sources/Bloom/Views/Center/AttachmentChip.swift",
        "/Users/freek/dev/code/Baton/Package.swift",
        "./relative/notes.md",
        "app/Http/Controllers/BeaconController.php",
        "icon@2x.png",
        "layout_v2.blade.php",
        "archive.tar.gz",
        "a.c",
        "vendor/bin/.phpunit.result.cache",
    ])
    func acceptsFiles(path: String) {
        #expect(FilePathGuess.looksLikeAFile(path))
    }

    // MARK: - What is not

    @Test("a glob is not a file", arguments: [
        "app/Beacon/**/*.php",
        "*.swift",
        "Sources/**",
        "{a,b}.php",
        "file?.txt",
        "[Tt]est.php",
    ])
    func rejectsGlobs(pattern: String) {
        #expect(!FilePathGuess.looksLikeAFile(pattern))
    }

    @Test("a command is not a file", arguments: [
        "pest --filter=Beacon",
        "npm run dev",
        "swift build -c release",
        "git status --porcelain",
        "cat Sources/Palette.swift",
        "./build.sh -r --run",
        "php artisan migrate",
        "rm -rf node_modules",
    ])
    func rejectsCommands(command: String) {
        #expect(!FilePathGuess.looksLikeAFile(command))
    }

    @Test("a pattern is not a file", arguments: [
        "\\bBeacon\\b",
        "func .*\\(",
        "^import",
        "TODO|FIXME",
        "class\\s+\\w+Controller",
    ])
    func rejectsPatterns(pattern: String) {
        #expect(!FilePathGuess.looksLikeAFile(pattern))
    }

    @Test("a URL is not a file", arguments: [
        "https://example.com/docs/a.php",
        "http://localhost:3000",
        "file:///Users/freek/notes.md",
    ])
    func rejectsURLs(url: String) {
        #expect(!FilePathGuess.looksLikeAFile(url))
    }

    @Test("a directory is not a file", arguments: [
        "Sources/Bloom",
        "app/Beacon/",
        "/Users/freek/dev/code/Baton",
        "node_modules",
        "..",
        "../Sources/Palette.swift",
    ])
    func rejectsDirectories(path: String) {
        #expect(!FilePathGuess.looksLikeAFile(path))
    }

    @Test("prose and numbers are not files", arguments: [
        "",
        "Beacon",
        "1.2.3",
        "Section 3.5",
        "-v",
        "~/notes.md",
        "a//b.php",
        "the file is called foo.php",
    ])
    func rejectsEverythingElse(text: String) {
        #expect(!FilePathGuess.looksLikeAFile(text))
    }

    @Test("a file with no extension keeps the monospace chip", arguments: [
        "Makefile",
        "LICENSE",
        ".gitignore",
        ".env",
        "bin/console",
    ])
    func rejectsExtensionlessFiles(path: String) {
        // Real files, deliberately refused: nothing in the string tells them apart from a
        // directory or a bare word, and a wrong icon costs more than a missing one.
        #expect(!FilePathGuess.looksLikeAFile(path))
    }

    @Test("a name with a space keeps the monospace chip")
    func rejectsNamesWithSpaces() {
        // The one rejection that hurts. `Read` and the composer both name such a file through the
        // tool's own contract instead, so this only bites on an argument nobody declared.
        #expect(!FilePathGuess.looksLikeAFile("CleanShot 2026-08-19 at 09.29.05@2x.png"))
    }

    @Test("an extension has to contain a letter")
    func requiresALetterInTheExtension() {
        #expect(FilePathGuess.looksLikeAFile("archive.7z"))
        #expect(!FilePathGuess.looksLikeAFile("release.2026"))
        #expect(!FilePathGuess.looksLikeAFile("notes.verylongext"))
    }

    // MARK: - Nothing is read from disk

    @Test("a file that no longer exists is still a file")
    func acceptsAMissingFile() {
        let gone = "Sources/Bloom/Views/\(UUID().uuidString).swift"

        #expect(!FileManager.default.fileExists(atPath: gone))
        #expect(FilePathGuess.looksLikeAFile(gone))
    }

    // MARK: - Well formed

    @Test("well formed is only about shape")
    func checksShapeOnly() {
        #expect(FilePathGuess.isWellFormed("CleanShot 2026-08-19 at 09.29.05@2x.png"))
        #expect(FilePathGuess.isWellFormed("Makefile"))
        #expect(!FilePathGuess.isWellFormed(""))
        #expect(!FilePathGuess.isWellFormed("two\nlines.php"))
        #expect(!FilePathGuess.isWellFormed(String(repeating: "a", count: FilePathGuess.maxLength + 1)))
    }

    // MARK: - Where it opens

    @Test("an absolute path inside the worktree comes back relative")
    func relativizesInside() {
        let worktree = "/Users/freek/dev/code/Baton"

        #expect(
            FilePathGuess.relative("\(worktree)/Sources/Palette.swift", to: worktree)
                == "Sources/Palette.swift"
        )
        #expect(FilePathGuess.relative("\(worktree)/README.md", to: worktree + "/") == "README.md")
    }

    @Test("a relative path is already relative to the worktree")
    func keepsRelative() {
        #expect(FilePathGuess.relative("Sources/Palette.swift", to: "/w") == "Sources/Palette.swift")
        #expect(FilePathGuess.relative("./Sources/Palette.swift", to: "/w") == "Sources/Palette.swift")
    }

    @Test("a path outside the worktree has nowhere to open", arguments: [
        "/Users/freek/.claude/CLAUDE.md",
        "/Users/freek/dev/code/BatonOther/Package.swift",
        "../Palette.swift",
        "~/notes.md",
        "/Users/freek/dev/code/Baton",
    ])
    func rejectsOutside(path: String) {
        #expect(FilePathGuess.relative(path, to: "/Users/freek/dev/code/Baton") == nil)
    }

    @Test("a sibling worktree whose name starts the same is still outside")
    func rejectsSharedPrefix() {
        // `/w/BatonTwo/a.swift` shares a prefix with `/w/Baton` and is not in it. The separator is
        // what makes that true, so it is asserted rather than assumed.
        #expect(FilePathGuess.relative("/w/BatonTwo/a.swift", to: "/w/Baton") == nil)
        #expect(FilePathGuess.relative("/w/Baton/a.swift", to: "/w/Baton") == "a.swift")
    }

    @Test("no worktree, nothing to resolve against")
    func rejectsEmptyWorktree() {
        #expect(FilePathGuess.relative("a.swift", to: "") == nil)
    }
}
