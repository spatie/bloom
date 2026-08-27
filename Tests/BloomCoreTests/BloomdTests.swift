import Testing
import Foundation
@testable import BloomCore

/// The daemon: how its version is read, when it gets copied, and what its answers decode to.
///
/// The JSON fixture below is real output from `bloomd status` running on a real Ubuntu server
/// against a real repository, not a hand-written sample. It is the one with the awkward paths in
/// it on purpose: a space, a tab and a non-ASCII character, which are the three things git's
/// default C-quoting would have rewritten and which `-z` and bytes are there to preserve.
@Suite("bloomd")
struct BloomdTests {
    // MARK: - Versioning

    @Test("the version is read out of the file's one literal")
    func versionLiteral() {
        #expect(Bloomd.version(of: "BLOOMD_VERSION = \"3\"\n") == "3")
        #expect(Bloomd.version(of: "#!/usr/bin/env python3\n\nBLOOMD_VERSION = \"12\"\n") == "12")
        // Whatever comes after the first assignment cannot change the answer, which is what stops
        // the word appearing in a docstring from being read as a second opinion.
        #expect(
            Bloomd.version(of: "BLOOMD_VERSION = \"1\"\n# BLOOMD_VERSION = \"9\"\n") == "1"
        )
        #expect(Bloomd.version(of: "nothing here\n") == nil)
        #expect(Bloomd.version(of: "BLOOMD_VERSION = \"\"\n") == nil)
    }

    /// **The file this build would actually install.** It is a resource in the bundle rather than
    /// something compiled in, so nothing but a test notices when it goes missing, and a Bloom that
    /// ships without it can install nothing.
    @Test("the shipped bloomd.py is present and says what version it is")
    func shippedFile() throws {
        let path = try #require(
            bloomdSourcePath(),
            "Resources/bloomd.py was not found by walking up from this test file"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let version = try #require(Bloomd.version(of: source))
        #expect(!version.isEmpty)
        // No third-party imports, which is the promise that makes installing it a file copy.
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import "), !trimmed.hasPrefix("import _") else { continue }
            let module = String(trimmed.dropFirst("import ".count))
                .components(separatedBy: ".")[0]
            #expect(
                ["json", "os", "subprocess", "sys"].contains(module),
                "bloomd.py imports \(module), which is not in the standard library set it promises"
            )
        }
    }

    @Test("where it goes on a server")
    func remotePath() {
        #expect(Bloomd.path(inHome: "/root") == "/root/.bloom/bin/bloomd")
        #expect(Bloomd.path(inHome: "/home/deploy") == "/home/deploy/.bloom/bin/bloomd")
    }

    /// The bundle layout: `Bloom.app/Contents/MacOS/Bloom` and `Bloom.app/Contents/Resources`.
    /// A pure function of a path, so it can be asserted on without a bundle.
    @Test("the bundled copy is found beside the executable")
    func sourceLookup() throws {
        let root = TestScratch.unique("bundle")
        let macos = root + "/Bloom.app/Contents/MacOS"
        let resources = root + "/Bloom.app/Contents/Resources"
        try FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)

        // Nothing there yet.
        #expect(Bloomd.sourcePath(beside: macos + "/Bloom", environment: [:]) == nil)

        try "BLOOMD_VERSION = \"1\"\n".write(
            toFile: resources + "/bloomd.py", atomically: true, encoding: .utf8
        )
        #expect(
            Bloomd.sourcePath(beside: macos + "/Bloom", environment: [:])
                == resources + "/bloomd.py"
        )

        // The override the test suite needs, because it runs from a mirrored package with no
        // bundle to look in.
        let elsewhere = TestScratch.unique("elsewhere") + ".py"
        try "BLOOMD_VERSION = \"2\"\n".write(toFile: elsewhere, atomically: true, encoding: .utf8)
        #expect(
            Bloomd.sourcePath(
                beside: macos + "/Bloom",
                environment: ["BLOOM_BLOOMD_PATH": elsewhere]
            ) == elsewhere
        )
    }

    // MARK: - When it gets copied

    @Test("nothing on the server means install it")
    func installsWhenAbsent() {
        #expect(
            Bloomd.decide(shipping: "1", installed: nil, hasPython: true)
                == .install(reason: .notThere, version: "1")
        )
        #expect(
            Bloomd.decide(shipping: "1", installed: "", hasPython: true)
                == .install(reason: .notThere, version: "1")
        )
    }

    /// Different, not older. A version is a string and Bloom only ships forward, so there is no
    /// ordering to get wrong.
    @Test("a different version means install it")
    func installsWhenDifferent() {
        #expect(
            Bloomd.decide(shipping: "2", installed: "1", hasPython: true)
                == .install(reason: .differentVersion("1"), version: "2")
        )
        // Including one that is somehow ahead, which is a downgrade of a dev build and is still
        // "make the server match this Bloom".
        #expect(Bloomd.decide(shipping: "2", installed: "7", hasPython: true).needsCopying)
    }

    /// The second install with an unchanged version is a no-op, which is what makes a checkup on
    /// every look cheap enough to do on every look.
    @Test("the same version is left alone")
    func noOpWhenCurrent() {
        let action = Bloomd.decide(shipping: "1", installed: "1", hasPython: true)
        #expect(action == .upToDate(version: "1"))
        #expect(!action.needsCopying)
    }

    @Test("no python3 means there is nothing that could run it")
    func impossibleWithoutPython() {
        #expect(Bloomd.decide(shipping: "1", installed: nil, hasPython: false) == .impossible)
        #expect(!Bloomd.decide(shipping: "1", installed: nil, hasPython: false).needsCopying)
    }

    // MARK: - What it answers with

    /// Real output, from a real repository, through a real SSH connection.
    static let realStatus = """
        {"additions":11,"ahead":0,"base":"main","behind":0,"branch":"feature","changed_files":8,\
        "deletions":3,"dirty":true,"files":[\
        {"additions":0,"binary":false,"change":"deleted","deletions":3,"old_path":null,\
        "path":"a.txt"},\
        {"additions":0,"binary":true,"change":"added","deletions":0,"old_path":null,\
        "path":"blob.bin"},\
        {"additions":1,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"caf\\u00e9.txt"},\
        {"additions":1,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"loose.txt"},\
        {"additions":5,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"renamed.txt"},\
        {"additions":1,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"spaced dir/a file with spaces.txt"},\
        {"additions":1,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"tabbed\\tname.txt"},\
        {"additions":2,"binary":false,"change":"added","deletions":0,"old_path":null,\
        "path":"untracked.txt"}],\
        "head":"334d9c3014894c8f67f19729834a58f76f93dc98",\
        "merge_base":"df0d377e251db6794ff5b1ea3e6d278fb12ed8b9","ok":true,"path":"/root/demo",\
        "upstream":null,"version":"1"}
        """

    @Test("a real status blob decodes")
    func decodesRealStatus() throws {
        let status = try BloomdStatus.decode(Self.realStatus, status: 0)
        #expect(status.version == "1")
        #expect(status.branch == "feature")
        #expect(status.head == "334d9c3014894c8f67f19729834a58f76f93dc98")
        #expect(status.mergeBase == "df0d377e251db6794ff5b1ea3e6d278fb12ed8b9")
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.changedFiles == 8)
        #expect(status.additions == 11)
        #expect(status.deletions == 3)
        #expect(status.dirty)
        #expect(status.files.count == 8)
    }

    /// The reason `bloomd` reads git's output as bytes and asks for `-z`. Git's default output
    /// C-quotes anything that is not plain ASCII, and splitting on tab or newline cuts a path in
    /// half. All three survived the whole trip: server, JSON, SSH, decoder.
    @Test("a path with a space, a tab and an accent survives the trip")
    func awkwardPaths() throws {
        let paths = try BloomdStatus.decode(Self.realStatus, status: 0).files.map(\.path)
        #expect(paths.contains("spaced dir/a file with spaces.txt"))
        #expect(paths.contains("tabbed\tname.txt"))
        #expect(paths.contains("café.txt"))
    }

    /// A binary file reports "-" for both counts, which `bloomd` keeps as a flag rather than
    /// silently counting as zero changed lines.
    @Test("a binary file is flagged rather than counted")
    func binary() throws {
        let status = try BloomdStatus.decode(Self.realStatus, status: 0)
        let blob = try #require(status.files.first { $0.path == "blob.bin" })
        #expect(blob.binary)
        #expect(blob.additions == 0)
    }

    @Test("a refusal carries the server's own message")
    func refusal() {
        #expect(throws: BloomdTrouble.refused("no such directory: /root/nope")) {
            try BloomdStatus.decode(#"{"ok": false, "error": "no such directory: /root/nope"}"#, status: 1)
        }
        #expect(
            throws: BloomdTrouble.refused(
                "fatal: not a git repository (or any of the parent directories): .git"
            )
        ) {
            try BloomdStatus.decode(
                #"{"ok": false, "error": "fatal: not a git repository (or any of the parent directories): .git"}"#,
                status: 1
            )
        }
    }

    /// Output nobody anticipated is quoted back rather than summarised, because that is exactly
    /// what somebody debugging needs to see. A login banner printed on stdout is the way this
    /// happens in real life.
    @Test("output that is not JSON is quoted back")
    func notJSON() {
        #expect(throws: BloomdTrouble.unreadable("Welcome to Ubuntu 26.04 LTS")) {
            try BloomdStatus.decode("Welcome to Ubuntu 26.04 LTS\n", status: 0)
        }
        #expect(throws: BloomdTrouble.unreadable("nothing, and it exited 127")) {
            try BloomdStatus.decode("", status: 127)
        }
    }
}

/// `Resources/bloomd.py`, found by walking up from this file, the way the session fixtures are.
/// There is no resource bundle: the core suite runs from a mirrored package with no app target.
func bloomdSourcePath() -> String? {
    let starts = [
        URL(fileURLWithPath: #filePath),
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath(),
    ]
    for start in starts {
        var directory = start.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Resources")
                .appendingPathComponent("bloomd.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            directory = directory.deletingLastPathComponent()
        }
    }
    return nil
}
