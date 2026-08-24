import Foundation

/// Whether a backticked run of a sent turn names a file, so the transcript can draw it as a file
/// rather than as a piece of code.
///
/// Bloom writes paths into the messages it sends on the owner's behalf, in a code span, which is
/// how `AttachmentDraft` writes every path in a prompt: "Follow the instructions in
/// `.bloom/scratch/pr-instructions.md`." A path is a file everywhere else in this window (the
/// composer's chips, a tool row's header, the turn footer), and in the one place the owner reads
/// his own request it came out as three backticked words in the middle of a sentence. This is the
/// rule that closes that gap.
///
/// **It is not `AttachmentDraft.isAttachment`, and the two are asked different questions.** That
/// one decides which files a draft is CARRYING, which the composer has to be right about because
/// it governs what gets sent; it says yes only to Bloom's own folder and to paths the composer
/// vouched for. This one decides what a sentence that has already gone is TALKING about, which
/// governs nothing but the drawing.
///
/// **It leans towards no, and that asymmetry is the whole design.** A false positive turns a piece
/// of somebody's prose into a pill, which reads as the app having lost the plot; a false negative
/// leaves a code span set as a code span, which is what happens today and what nobody has
/// complained about. So a span has to say it is a path in one of two unambiguous ways, and
/// everything else stays words.
public enum FileMention: Sendable {
    /// Whether this span, taken from between a pair of backticks, names a file.
    ///
    /// `FilePathGuess.looksLikeAFile` does the first half: it throws out globs, patterns, URLs,
    /// flags, directories and anything with whitespace in it, and requires a last component with a
    /// plausible extension on it. What it cannot throw out is a dotted identifier, because
    /// `NSApp.activate` and `config.yml` are the same shape and it was written to answer about
    /// tool arguments, where the tool has usually already promised the field is a file. In a
    /// sentence nothing has promised anything, so a second test is needed and it is this:
    ///
    /// - A span with a `/` in it is a path. `.bloom/scratch/pr-instructions.md`,
    ///   `Sources/Bloom/Views/Palette.swift`, `app/Http/Kernel.php`. Nothing that reads as prose
    ///   or as an expression carries a slash and ends in a component with an extension.
    /// - A bare name has to end in an extension this app recognises. `foo.md` is a file;
    ///   `NSApp.activate` is a method, `store.state` is a property, `Duration.seconds` is a
    ///   factory, and no shape rule tells them from `notes.txt`: `swift` is five letters and
    ///   `activate` is eight, so length says nothing.
    ///
    /// A list is a maintenance cost and it is bought deliberately. The alternative is guessing,
    /// and the file that pays for a wrong guess is the owner's own sentence.
    public static func names(_ span: String) -> Bool {
        guard FilePathGuess.looksLikeAFile(span) else { return false }
        if span.contains("/") { return true }
        guard let dot = span.lastIndex(of: ".") else { return false }
        return extensions.contains(span[span.index(after: dot)...].lowercased())
    }

    /// What the turn is made of: the words, and the files named in them.
    ///
    /// The backtick walking is `AttachmentDraft.parse`'s, not a second copy of it. That scanner
    /// already knows what an unclosed backtick means and where a span that turned out not to be a
    /// file leaves the cursor, and a parser kept in two places drifts at the first edit to either.
    public static func segments(in text: String) -> [AttachmentDraft.Segment] {
        AttachmentDraft.parse(text, alsoNaming: names).segments
    }

    /// The extensions a bare name may end in.
    ///
    /// Everything a repository this app is used on actually holds, minus every one that is also a
    /// common member or method name. Those omissions are the interesting entries in the list,
    /// because each is a real file type given up on purpose:
    ///
    /// - `log`, because `console.log` and `logger.log` are written in chat far more often than
    ///   `build.log` is, and a real log file is nearly always named with its folder in front of
    ///   it, where the slash rule above takes it.
    /// - `map`, for `array.map`. `data`, for `response.data`. `env`, for `process.env`, and a
    ///   bare `.env` is rejected a step earlier anyway: it has no stem, so it is a dotfile rather
    ///   than a name with an extension.
    /// - `app`, for `model.app`, which is written in this repository every day. `Bloom.app` loses
    ///   its pill and keeps its code span, which is the cheap half of the trade.
    ///
    /// `json` is in, against `res.json`, because a JSON file is named in a sentence constantly and
    /// the method is nearly always written with its brackets, which `FilePathGuess` rejects.
    ///
    /// Nothing longer than eight characters is worth listing: `FilePathGuess.hasExtension` caps an
    /// extension there, so `Info.entitlements` and `Bloom.xcodeproj` never reach this set.
    private static let extensions: Set<String> = [
        // Code
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "go", "rs", "java", "kt", "kts",
        "rb", "py", "php", "pl", "lua", "scala", "dart", "ex", "exs", "erl", "hs", "clj",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte",
        // Markup, style and prose
        "md", "markdown", "mdx", "txt", "rtf", "html", "htm", "xml", "svg", "css", "scss", "sass",
        "less", "twig", "erb", "haml", "hbs", "ejs", "pug",
        // Configuration and data
        "json", "yml", "yaml", "toml", "ini", "cfg", "conf", "plist", "lock", "resolved",
        "gradle", "csv", "tsv", "sql", "graphql", "proto", "xcconfig", "pbxproj", "xib",
        "podspec", "gemspec",
        // Shells and scripts
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "mk", "cmake",
        // Pictures, documents and archives
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "pdf",
        "mov", "mp4", "m4v", "webm", "gz", "tgz", "zip", "tar", "bz2", "xz", "dmg",
        // Artefacts a sentence names by their extension
        "sqlite", "patch", "diff",
    ]
}
