import Foundation
import Testing
@testable import BloomCore

@Suite("Loading multiple file icon packs")
@MainActor
struct FileIconPackLibraryTests {
    @Test("visible rows share one download and switching back reuses the loaded pack")
    func coalescesLoads() async throws {
        let calls = Calls()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let pack = try fixture()
        let library = FileIconPackLibrary { choice in
            await calls.record(choice)
            for await _ in stream { break }
            return pack
        }
        let first = try #require(library.prepare(.vscodeIcons))
        let second = try #require(library.prepare(.vscodeIcons))
        #expect(library.loading.contains(.vscodeIcons))
        continuation.yield(())
        await first.value
        await second.value
        #expect(await calls.count(.vscodeIcons) == 1)
        #expect(library.packs[.vscodeIcons] != nil)
        let cached = library.prepare(.vscodeIcons)
        #expect(cached == nil)
        #expect(library.loading.isEmpty)
    }

    @Test("a slow previous download cannot replace another pack's artwork")
    func independentPacks() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let original = try fixture(marker: 1)
        let material = try fixture(marker: 2)
        let library = FileIconPackLibrary { choice in
            if choice == .vscodeIcons {
                for await _ in stream { break }
                return original
            }
            return material
        }
        let first = try #require(library.prepare(.vscodeIcons))
        let second = try #require(library.prepare(.material))
        await second.value
        #expect(library.packs[.material]?.artwork["file"] == Data([2]))
        continuation.yield(())
        await first.value
        #expect(library.packs[.material]?.artwork["file"] == Data([2]))
        #expect(library.packs[.vscodeIcons]?.artwork["file"] == Data([1]))
    }

    @Test("download errors allow an explicit retry without repeated automatic requests")
    func retries() async throws {
        let calls = Calls()
        let pack = try fixture()
        let library = FileIconPackLibrary { choice in
            await calls.record(choice)
            if await calls.count(choice) == 1 { throw Failure() }
            return pack
        }
        let first = try #require(library.prepare(.symbols))
        await first.value
        #expect(library.errors[.symbols] != nil)
        let automaticRetry = library.prepare(.symbols)
        #expect(automaticRetry == nil)
        let retry = try #require(library.prepare(.symbols, retry: true))
        await retry.value
        #expect(library.errors[.symbols] == nil)
        #expect(library.packs[.symbols] != nil)
        #expect(await calls.count(.symbols) == 2)
        let builtIn = library.prepare(.bloom)
        #expect(builtIn == nil)
    }

    private func fixture(marker: UInt8 = 1) throws -> FileIconPackInstaller.Pack {
        let theme = try JSONDecoder().decode(FileIconTheme.self, from: Data(FileIconThemeTests.manifest.utf8))
        return FileIconPackInstaller.Pack(theme: theme, artwork: ["file": Data([marker])])
    }

    private struct Failure: Error {}

    private actor Calls {
        private var counts: [FileIconPack: Int] = [:]
        func record(_ pack: FileIconPack) { counts[pack, default: 0] += 1 }
        func count(_ pack: FileIconPack) -> Int { counts[pack, default: 0] }
    }
}
