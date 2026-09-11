import Foundation
import Testing
@testable import BloomCore

@Suite("Editor navigation and editing", .scratchDirectory)
struct EditorExperienceTests {
    @Test func locationsPreservePathsAndColumns() {
        #expect(CodeLocation.parse("Sources/My File.swift:42:7") == CodeLocation(path: "Sources/My File.swift", line: 42, column: 7))
        #expect(CodeLocation.parse("foo.php#L19-L23") == CodeLocation(path: "foo.php", line: 19))
        #expect(CodeLocation.parse("file.swift") == CodeLocation(path: "file.swift"))
        #expect(CodeLocation.parse("file.swift:0").line == 1)
    }

    @Test func definitionMatchesOnlyTheClickedSymbol() {
        let source = "<?php\nclass Customer {}\nnew Customer();\n"
        let definition = CodeLocation(path: "/tmp/project/Customer.php", line: 2, column: 7)
        let declaration = (source as NSString).range(of: "Customer").location
        #expect(definition.matchesSymbol(path: "Customer.php", root: "/tmp/project", text: source, offset: declaration + 4))
        #expect(!definition.matchesSymbol(path: "Other.php", root: "/tmp/project", text: source, offset: declaration))
        #expect(!definition.matchesSymbol(path: "Customer.php", root: "/tmp/project", text: source, offset: declaration - 2))
        #expect(!definition.matchesSymbol(path: "Customer.php", root: "/tmp/project", text: source, offset: source.utf16.count - 7))
        #expect(!definition.matchesSymbol(path: "Customer.php", root: "/tmp/project", text: source, offset: source.utf16.count))
        let unicode = "class Café {}"
        #expect(CodeLocation(path: "a.php", column: 7).matchesSymbol(path: "a.php", root: "/tmp/project", text: unicode, offset: 9))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_LOCAL_LSP"] == "1"))
    func phpReferencesFindCallersAndExcludeDeclaration() async throws {
        let root = TestScratch.path("php-references")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let declaration = "<?php\nclass NavigationCustomer {}\n"
        let caller = "<?php\nnew NavigationCustomer();\n"
        try declaration.write(toFile: root + "/Customer.php", atomically: true, encoding: .utf8)
        try caller.write(toFile: root + "/Caller.php", atomically: true, encoding: .utf8)
        let offset = (declaration as NSString).range(of: "NavigationCustomer").location
        let server = SourceLanguageServer()
        do {
            let references = try await server.references(root: root, path: "Customer.php", text: declaration, offset: offset, language: .php)
            #expect(references.contains { $0.path.hasSuffix("/Caller.php") && $0.line == 2 })
            #expect(!references.contains { $0.path.hasSuffix("/Customer.php") })
            let definitions = try await server.definition(root: root, path: "Customer.php", text: declaration, offset: offset, language: .php)
            #expect(definitions.contains { $0.matchesSymbol(path: "Customer.php", root: root, text: declaration, offset: offset + 3) })
            await server.close()
        } catch {
            await server.close()
            throw error
        }
    }

    @Test func laravelRootsStayInsideTheWorkspace() throws {
        let root = TestScratch.path("workspace")
        for directory in [root, root + "/apps/blog", root + "-other"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try "".write(toFile: directory + "/artisan", atomically: true, encoding: .utf8)
            try "{}".write(toFile: directory + "/composer.json", atomically: true, encoding: .utf8)
        }
        #expect(SourceLanguageServers.laravelRoot(path: "apps/blog/app/Controller.php", root: root) == root + "/apps/blog")
        #expect(SourceLanguageServers.laravelRoot(path: "app/Controller.php", root: root) == root)
        #expect(SourceLanguageServers.laravelRoot(path: root + "-other/Controller.php", root: root) == nil)
        #expect(SourceLanguageServers.laravelRoot(path: "../Controller.php", root: root) == nil)
        try FileManager.default.removeItem(atPath: root + "/composer.json")
        #expect(SourceLanguageServers.laravelRoot(path: "app/Controller.php", root: root) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLOOM_LARAVEL_LSP_VENDOR"] != nil), .timeLimit(.minutes(2)))
    func laravelViewsAndPhpDefinitionsWorkTogether() async throws {
        let vendor = try #require(ProcessInfo.processInfo.environment["BLOOM_LARAVEL_LSP_VENDOR"])
        let root = TestScratch.path("laravel")
        for directory in ["bootstrap/cache", "resources/views/front/blog", "storage/framework/views", "storage/logs", "config"] {
            try FileManager.default.createDirectory(atPath: root + "/" + directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: root + "/vendor", withDestinationPath: vendor)
        let files = [
            "composer.json": "{}",
            "artisan": """
            <?php
            require __DIR__.'/vendor/autoload.php';
            $app = require __DIR__.'/bootstrap/app.php';
            exit($app->handleCommand(new Symfony\\Component\\Console\\Input\\ArgvInput));
            """,
            "bootstrap/app.php": """
            <?php
            return Illuminate\\Foundation\\Application::configure(basePath: dirname(__DIR__))
                ->withProviders([Laravel\\Tinker\\TinkerServiceProvider::class])
                ->withExceptions()
                ->create();
            """,
            "config/view.php": "<?php return ['paths' => [resource_path('views')], 'compiled' => storage_path('framework/views')];",
            "resources/views/front/blog/index.blade.php": "<h1>Blog</h1>",
            "Caller.php": "<?php view('missing.on.disk');",
        ]
        for (path, contents) in files { try contents.write(toFile: root + "/" + path, atomically: true, encoding: .utf8) }
        let servers = SourceLanguageServers()
        do {
            let source = "<?php class NavigationBlog {} new NavigationBlog(); view('front.blog.index');"
            let definitions = try await servers.definition(root: root, path: "Caller.php", text: source,
                offset: (source as NSString).range(of: "front.blog.index").location + 3, language: .php)
            #expect(definitions == [CodeLocation(path: root + "/resources/views/front/blog/index.blade.php")])
            let php = try await servers.definition(root: root, path: "Caller.php", text: source,
                offset: (source as NSString).range(of: "NavigationBlog", options: .backwards).location + 3, language: .php)
            #expect(php.contains { $0.path.hasSuffix("/Caller.php") && $0.column == 13 })

            try FileManager.default.moveItem(atPath: root + "/resources/views/front/blog/index.blade.php",
                toPath: root + "/resources/views/front/blog/renamed.blade.php")
            let blade = "@include('front.blog.renamed')"
            var renamed: [CodeLocation] = []
            for _ in 0..<10 where renamed.isEmpty {
                try await Task.sleep(for: .milliseconds(500))
                renamed = try await servers.definition(root: root, path: "resources/views/page.blade.php", text: blade,
                    offset: (blade as NSString).range(of: "front.blog.renamed").location + 3, language: .blade)
            }
            #expect(renamed == [CodeLocation(path: root + "/resources/views/front/blog/renamed.blade.php")])
            let removed = try await servers.definition(root: root, path: "Caller.php", text: source,
                offset: (source as NSString).range(of: "front.blog.index").location + 3, language: .php)
            #expect(removed.isEmpty)
            await servers.close()
        } catch {
            await servers.close()
            throw error
        }
    }

    @Test func definitionPathsRespectProjectBoundaries() {
        #expect(CodeLocation(path: "/tmp/project/src/My File.php").displayPath(relativeTo: "/tmp/project/") == "src/My File.php")
        #expect(CodeLocation(path: "/tmp/project-other/file.php").displayPath(relativeTo: "/tmp/project") == "/tmp/project-other/file.php")
        #expect(CodeLocation(path: "src/File.php").displayPath(relativeTo: "/tmp/project") == "src/File.php")
    }

    @Test func definitionsKeepServerOrderWithinIgnoreGroups() {
        let dependency = CodeLocation(path: "/tmp/project/vendor/Class.php", line: 9)
        let first = CodeLocation(path: "/tmp/project/src/B.php", line: 2)
        let second = CodeLocation(path: "/tmp/project/src/A.php", line: 3)
        let external = CodeLocation(path: "/tmp/other/Class.php")
        let results = CodeLocation.suggestions([dependency, first, second, first, external], root: "/tmp/project", ignored: ["vendor/Class.php"])
        #expect(results == [first, second, external, dependency])
    }

    @Test func definitionsPutLaravelIdeaHelpersAfterRealVendorCode() {
        let root = "/tmp/project"
        let helper = CodeLocation(path: root + "/vendor/_laravel_idea/_ide_helper_macro.php", line: 253)
        let staticHelper = CodeLocation(path: root + "/vendor/_laravel_idea/_ide_helper_macro_static.php", line: 217)
        let implementation = CodeLocation(path: root + "/vendor/laravel/framework/src/Illuminate/Collections/Collection.php", line: 24)
        let application = CodeLocation(path: root + "/app/Collection.php")
        let ignored = Set([helper, staticHelper, implementation].map { $0.displayPath(relativeTo: root) })
        let results = CodeLocation.suggestions([helper, staticHelper, implementation, application], root: root, ignored: ignored)
        #expect(results == [application, implementation, helper, staticHelper])
        #expect(CodeLocation.suggestions([helper, staticHelper], root: root, ignored: []) == [helper, staticHelper])
    }

    @Test func helperPriorityRequiresTheExactVendorDirectory() {
        let ordinary = CodeLocation(path: "/tmp/project/vendor/_laravel_idea_extension/File.php")
        let helper = CodeLocation(path: "/tmp/project/packages/app/vendor/_laravel_idea/_ide_helper.php")
        let results = CodeLocation.suggestions([helper, ordinary], root: "/tmp/project", ignored: ["vendor/_laravel_idea_extension/File.php"])
        #expect(results == [ordinary, helper])
    }

    @Test func definitionsUseGitIgnoreRules() async throws {
        let root = TestScratch.path("definitions")
        try FileManager.default.createDirectory(atPath: root + "/vendor", withIntermediateDirectories: true)
        _ = try await Git.run(["init"], in: root)
        try "vendor/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        let dependency = CodeLocation(path: root + "/vendor/Class.php")
        let source = CodeLocation(path: root + "/App.php")
        let results = await CodeLocation.suggestions([dependency, source], root: root)
        #expect(results == [source, dependency])
    }

    @Test func unicodeAndLineEndings() {
        let text = "a\r\n😀xyz\r\n"
        #expect(CodeLocation.offset(in: text, line: 2, column: 3) == 5)
        #expect(CodeLocation.offset(in: text, line: 2, column: 2) == 3)
        #expect(CodeLocation.offset(in: text, line: 200) == text.utf16.count)
        #expect(CodeLocation.position(in: text, offset: 6).line == 2)
        #expect(CodeLocation.position(in: text, offset: 6).column == 4)
    }

    @Test func historyBranchesAndRestoresPosition() {
        var history = SourceHistory()
        history.visit(CodeLocation(path: "a.swift"))
        history.updateCurrent(CodeLocation(path: "a.swift", line: 30))
        history.visit(CodeLocation(path: "b.swift"))
        let back = history.move(-1)
        #expect(back?.line == 30)
        #expect(history.canGoForward)
        history.visit(CodeLocation(path: "c.swift"))
        #expect(!history.canGoForward)
        #expect(history.entries.map(\.path) == ["a.swift", "c.swift"])
    }

    @Test func indentDoesNotTouchFollowingLine() throws {
        let source = "one\ntwo\nthree"
        let edit = try #require(SourceEditing.lines(in: source, selection: NSRange(location: 0, length: 8), command: .indent, language: .swift))
        #expect(edit.replacement == "    one\n    two\n")
        #expect((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement).hasSuffix("\nthree"))
    }

    @Test func commentsRoundTripAndPreserveCRLF() throws {
        let source = "  let a = 1\r\n  let b = 2\r\n"
        let edit = try #require(SourceEditing.lines(in: source, selection: NSRange(location: 0, length: source.utf16.count), command: .comment, language: .swift))
        #expect(edit.replacement == "  // let a = 1\r\n  // let b = 2\r\n")
        let undo = try #require(SourceEditing.lines(in: edit.replacement, selection: edit.selection, command: .comment, language: .swift))
        #expect(undo.replacement == source)
    }

    @Test func markupCommentRoundTrips() throws {
        let text = "  <div>Hello</div>\n"
        let edit = try #require(SourceEditing.lines(in: text, selection: NSRange(location: 0, length: text.utf16.count), command: .comment, language: .html))
        #expect(edit.replacement == "  <!-- <div>Hello</div> -->\n")
        let undo = try #require(SourceEditing.lines(in: edit.replacement, selection: edit.selection, command: .comment, language: .html))
        #expect(undo.replacement == text)
    }

    @Test func newlineUsesExistingIndentation() {
        let text = "\tif ready {"
        let edit = SourceEditing.newline(in: text, selection: NSRange(location: text.utf16.count, length: 0))
        #expect(edit.replacement == "\n\t\t")
    }

    @Test func bracketsIgnoreCommentsAndStrings() {
        let text = "foo(\" ) \" /* ) */ bar())"
        #expect(SourceEditing.matchingBracket(in: text, at: 3, language: .swift) == text.utf16.count - 1)
        #expect(SourceEditing.matchingBracket(in: text, at: 6, language: .swift) == nil)
    }

    @Test func relativeImportsAndLineLocations() {
        let found = SourceSearch.resolve("../lib/value:12", from: "src/main.ts", root: "/tmp/repo", paths: ["lib/value.ts"])
        #expect(found == CodeLocation(path: "lib/value.ts", line: 12))
        #expect(SourceSearch.resolve("missing", from: "src/main.ts", root: "/tmp/repo", paths: []) == nil)
    }

    @Test func searchSkipsBinaryAndEscapingSymlinks() throws {
        let root = TestScratch.path("repo")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "hello\nneedle here\n".write(toFile: root + "/test.swift", atomically: true, encoding: .utf8)
        try Data("needle\0binary".utf8).write(to: URL(fileURLWithPath: root + "/binary"))
        let outside = TestScratch.path("outside")
        try "needle".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        let found = try SourceSearch.search(root: root, paths: ["binary", "link", "test.swift"], query: "NEEDLE")
        #expect(found.count == 1)
        #expect(found.first?.location == CodeLocation(path: "test.swift", line: 2))
    }

    @Test func symbolsIgnoreQuotedDeclarations() {
        let text = "// func nope()\nfunc yes() {}\nlet quote = \"class No\"\n"
        let found = SourceSearch.symbols(in: text, path: "demo.swift")
        #expect(found.map(\.location.line) == [2, 3])
    }

    @Test func sourceLinksStayInternal() throws {
        let url = try #require(SourceReference.url("Sources/My File.swift:42:7"))
        #expect(SourceReference.location(url) == CodeLocation(path: "Sources/My File.swift", line: 42, column: 7))
        #expect(!LinkPolicy.opens(url))
        #expect(SourceReference.url("https://example.com/file.swift") == nil)
        #expect(SourceReference.links(in: "See src/File.swift:42 and other.php#L12").count == 2)
    }

    @Test func embeddedLanguagesCarryAcrossLines() {
        let source = "<script lang=\"ts\">\nconst count = 42;\n</script>\n<div>{{ count + 1 }}</div>"
        let tokens = SyntaxHighlighter.tokenize(source: source, language: .vue)
        #expect(tokens[1].contains { $0.kind == .keyword && $0.range == 0..<5 })
        #expect(tokens[1].contains { $0.kind == .number })
        #expect(tokens[3].contains { $0.kind == .number })
        let blade = SyntaxHighlighter.tokenize(source: "{{ $user->name }}", language: .blade)
        #expect(blade[0].contains { $0.kind == .variable })
    }

    @Test func jsxAttributesAndExpressionsHaveDifferentTokens() {
        let text = "const view = <Button disabled={true} title=\"Go\" />"
        let tokens = SyntaxHighlighter.tokenize(source: text, language: .typescript)[0]
        let ns = text as NSString
        let attributes = tokens.filter { $0.kind == .attribute }.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(attributes.contains("disabled"))
        #expect(attributes.contains("title"))
        #expect(tokens.contains { $0.kind == .constant })
    }

    @Test func framesHandleFragmentedUnicodeAndMultipleMessages() throws {
        let first = Data(#"{"id":1,"result":"café"}"#.utf8)
        let second = Data(#"{"id":2,"result":null}"#.utf8)
        let packet = Data("Content-Length: \(first.count)\r\n\r\n".utf8) + first
            + Data("Content-Length: \(second.count)\r\n\r\n".utf8) + second
        var frames = LanguageServerFrames()
        var messages: [JSONValue] = []
        for byte in packet {
            let read = try frames.append(Data([byte]))
            messages += read
        }
        #expect(messages.count == 2)
        #expect(messages.first?["result"]?.stringValue == "café")
    }

    @Test func malformedFramesFail() {
        var frames = LanguageServerFrames()
        #expect(throws: (any Error).self) {
            _ = try frames.append(Data("Content-Length: -1\r\n\r\n".utf8))
        }
    }

    @Test func draftsKeepTypingDuringSaveAndRefuseAgentOverwrites() throws {
        let path = TestScratch.path("draft.swift")
        try "before".write(toFile: path, atomically: true, encoding: .utf8)
        let baseline = try FileEditor.read(path)
        var draft = SourceDraft(baseline: baseline, text: "saved")
        let saved = try FileEditor.write(draft.text, over: baseline)
        draft.text = "typing continued"
        draft.didSave(saved)
        #expect(draft.text == "typing continued")
        #expect(draft.isDirty)
        try "agent version".write(toFile: path, atomically: true, encoding: .utf8)
        let disk = try FileEditor.read(path)
        let accepted = draft.acceptDisk(disk)
        #expect(!accepted)
        #expect(draft.text == "typing continued")
        draft.text = draft.baseline.text
        let refreshed = draft.acceptDisk(disk)
        #expect(refreshed)
        #expect(draft.text == "agent version")
    }

    @Test func definitionLinksNormaliseRepeatedPathSeparators() throws {
        let response = try #require(JSONValue.parse(#"[{"targetUri":"file:///tmp/My%20Project//resources/views/front/blog/index.blade.php","targetSelectionRange":{"start":{"line":0,"character":0}}}]"#))
        let locations = SourceLanguageServer.locations(response)
        #expect(locations == [CodeLocation(path: "/tmp/My Project/resources/views/front/blog/index.blade.php")])
        #expect(locations.first?.displayPath(relativeTo: "/tmp/My Project") == "resources/views/front/blog/index.blade.php")
    }

    @Test func definitionLinksUseSelectionRange() throws {
        let response = try #require(JSONValue.parse(#"[{"targetUri":"file:///tmp/My%20File.swift","targetRange":{"start":{"line":0,"character":0}},"targetSelectionRange":{"start":{"line":10,"character":5}}}]"#))
        #expect(SourceLanguageServer.locations(response) == [CodeLocation(path: "/tmp/My File.swift", line: 11, column: 6)])
    }
}
