import Testing
@testable import BloomCore

/// The sidebar draws a project as a coloured tile with its initials on it, and the initials are
/// the only half of that mark that can be wrong. Ten accent colours repeat once an eleventh
/// project is added, so these two characters are what actually tells two projects apart.
@Suite("Project monograms")
struct RepoMonogramTests {
    @Test("takes one letter from each of the first two words", arguments: [
        // The name that started this: Conductor draws `there-there` as `tt`.
        ("there-there", "TT"),
        ("laravel-backup", "LB"),
        ("my_app", "MA"),
        ("freek.dev", "FD"),
        ("Bloom Core", "BC"),
        ("spatie/laravel-pdf", "SL"),
    ])
    func twoWords(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    @Test("takes two letters from a name that is one word", arguments: [
        ("bloom", "BL"),
        ("Bloom", "BL"),
        ("conductor", "CO"),
    ])
    func oneWord(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    /// A folder called `my-app-2` is still the app. Counting the 2 as a word would give `M2`,
    /// which says nothing about which app it is.
    @Test("skips a word that is only digits", arguments: [
        ("my-app-2", "MA"),
        ("app-2", "AP"),
        ("2-factor-auth", "FA"),
    ])
    func skipsNumbers(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    /// Only when there is nothing else, because two digits still identify the project and an
    /// empty tile does not.
    @Test("falls back to digits when the name has no letters at all", arguments: [
        ("2048", "20"),
        ("360", "36"),
        ("8", "8"),
    ])
    func digitsOnly(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    @Test("treats a camel hump as a word break", arguments: [
        ("MyApp", "MA"),
        ("BloomCore", "BC"),
        ("iOSClient", "IO"),
    ])
    func camelCase(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    /// A run of capitals is left alone: `HTTPServer` is one word as far as this is concerned, so
    /// the mark stays the first two characters of the name the folder actually has.
    @Test("does not break inside a run of capitals")
    func acronym() {
        #expect(RepoMonogram.initials(for: "HTTPServer") == "HT")
    }

    /// An emoji is already a mark. Reducing "🌸 garden" to "G" throws away the character the
    /// user chose to be recognised by.
    @Test("keeps a leading emoji as the whole monogram", arguments: [
        ("🌸 garden", "🌸"),
        ("🚀", "🚀"),
        ("🇧🇪-site", "🇧🇪"),
        ("❤️-notes", "❤️"),
    ])
    func leadingEmoji(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    /// Trailing, so the word is still what names the project.
    @Test("ignores an emoji that is not first")
    func trailingEmoji() {
        #expect(RepoMonogram.initials(for: "bloom 🌸") == "BL")
    }

    @Test("uppercases without widening the monogram")
    func sharpS() {
        // "ß".uppercased() is "SS", which would make a three character mark out of a two
        // character rule and overflow the tile.
        #expect(RepoMonogram.initials(for: "ßeta-release").count == 2)
        #expect(RepoMonogram.initials(for: "ßeta") == "SE")
    }

    @Test("keeps letters outside ASCII", arguments: [
        ("ærø-tools", "ÆT"),
        ("Ünster", "ÜN"),
        ("日本語", "日本"),
    ])
    func unicodeLetters(name: String, initials: String) {
        #expect(RepoMonogram.initials(for: name) == initials)
    }

    /// The tile draws its colour and no letters rather than a `?`, so an empty answer is the
    /// contract and not an oversight.
    @Test("gives nothing back when there is nothing to take", arguments: ["", "   ", "---", "//"])
    func nothingToTake(name: String) {
        #expect(RepoMonogram.initials(for: name).isEmpty)
    }

    @Test("never returns more than two characters", arguments: [
        "there-there", "bloom", "a-very-long-project-name-indeed", "2048", "ærø", "ßeta",
    ])
    func neverWiderThanTwo(name: String) {
        #expect(RepoMonogram.initials(for: name).count <= 2)
    }
}

/// An emoji mark is not a column of its own: it is the first character of the project's name, and
/// the settings window edits it by editing the name. These pin what may be taken off that name and
/// what is left when it is.
@Suite("Emoji marks in a project name")
struct RepoMarkTests {
    @Test("reads the leading emoji as the mark", arguments: [
        ("🌸 Garden", "🌸"),
        ("🌸Garden", "🌸"),
        ("🌸", "🌸"),
    ])
    func readsLeadingEmoji(name: String, expected: String) {
        #expect(RepoMonogram.mark(in: name) == expected)
    }

    @Test("finds no mark where the name has none", arguments: [
        // Only a LEADING emoji is a mark, which is the same rule `initials(for:)` draws by.
        "bloom 🌸", "there-there", "2048", "", "   ",
    ])
    func findsNoMark(name: String) {
        #expect(RepoMonogram.mark(in: name).isEmpty)
    }

    @Test("takes the emoji off and tidies the space behind it")
    func stripsTheMark() {
        #expect(RepoMonogram.nameWithoutMark("🌸 Garden") == "Garden")
        #expect(RepoMonogram.nameWithoutMark("🌸Garden") == "Garden")
    }

    @Test("leaves a name that carries no mark exactly as it is")
    func leavesUnmarkedNames() {
        #expect(RepoMonogram.nameWithoutMark("Garden") == "Garden")
        #expect(RepoMonogram.nameWithoutMark("bloom 🌸") == "bloom 🌸")
    }

    /// The case that has a wrong answer. Stripping the mark off a project called nothing but an
    /// emoji leaves no name at all, so the caller has to be able to tell, and Use initials is
    /// disabled rather than offered and doing nothing.
    @Test("answers with nothing when the emoji was the whole name")
    func emojiOnlyNameStripsToNothing() {
        #expect(RepoMonogram.nameWithoutMark("🌸").isEmpty)
        #expect(RepoMonogram.nameWithoutMark("🌸   ").isEmpty)
    }
}
