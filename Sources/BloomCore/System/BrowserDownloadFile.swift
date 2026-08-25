import Foundation

/// What a file a page hands over is called on disk, and how far it has got.
///
/// **The suggested name is written by the page and is the whole reason this exists.** It arrives
/// from `Content-Disposition` or from a `download` attribute, which is to say from whoever wrote
/// the server, and it lands in a call that creates a file on the owner's Mac. A name of
/// `../../.zshrc` is a path and not a name; a name beginning with a dot is a file Finder will not
/// show him; a name with a control character in it draws as something other than what it is; and a
/// name that already exists is somebody else's file about to be written over. Every one of those
/// is answered here rather than trusted, and the answers are tested.
public enum BrowserDownloadFile {
    /// The longest a name may be. HFS+ and APFS both stop at 255 bytes, and a name near that in
    /// UTF-8 is a name that fails to write for reasons nobody can read, so this leaves room.
    public static let nameLimit = 200

    /// What Bloom is willing to call a file a page offered.
    ///
    /// The last path component and nothing else, so a name that is really a path can only ever
    /// name a file in the folder downloads go to. Leading dots go, because a page that names its
    /// file `.zshrc` has chosen a name the reader will not see in Finder, and a download he cannot
    /// see is a download he cannot check. Control characters go for the same reason: a name is
    /// something to be read.
    ///
    /// **The extension is kept, deliberately.** Taking it off would make every download open in
    /// whatever Launch Services guesses, and a `.zip` that has stopped saying `.zip` is worse than
    /// one that says it. What protects the reader is that the file lands in Downloads with the
    /// quarantine flag on it, which is Gatekeeper's business rather than this function's.
    public static func name(from suggested: String) -> String {
        // Characters first and the path afterwards, because a NUL between two slashes would
        // otherwise become part of a component. Not `URL(fileURLWithPath:)`, which was tried and
        // is the wrong tool twice over: it resolves a relative path against the working directory,
        // so ".." came back as the name of the folder the process happened to be in, and it
        // percent encodes what it cannot hold, so a NUL came back as the four characters "%00".
        var name = String(suggested.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != ":"
        })

        name = name.split(separator: "/").last.map(String.init) ?? ""
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return "download" }
        return shortened(name)
    }

    /// A name a page offered, cut to something a file system will take, with its extension left on
    /// the end where it belongs.
    private static func shortened(_ name: String) -> String {
        guard name.count > nameLimit else { return name }
        let parts = parted(name)
        // An "extension" of forty characters is not one, it is the tail of a long name, and
        // keeping it would leave nothing of the part a reader recognises.
        guard !parts.ext.isEmpty, parts.ext.count <= 20 else {
            return String(name.prefix(nameLimit))
        }
        return String(parts.stem.prefix(nameLimit - parts.ext.count - 1)) + "." + parts.ext
    }

    /// A name split at its last full stop, or the whole of it and nothing when there is no
    /// extension to speak of. A leading dot is already gone by the time anything asks.
    static func parted(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    /// The name to write, given what is already in the folder.
    ///
    /// **A download never writes over a file that is already there.** The folder is the reader's
    /// own Downloads, which has his things in it, and a page choosing the name means a page could
    /// choose one of them. Numbered like Safari does it, `report-2.pdf` after `report.pdf`, so the
    /// second copy of a thing is recognisably the second copy.
    ///
    /// `isTaken` is asked rather than a listing being taken, because the folder can hold thousands
    /// of files and because the only question is about the handful of names this one could use.
    public static func filename(for suggested: String, isTaken: (String) -> Bool) -> String {
        let name = name(from: suggested)
        guard isTaken(name) else { return name }

        for number in 2...1_000 {
            let candidate = numbered(name, number)
            if !isTaken(candidate) { return candidate }
        }
        // A thousand files of the same name is not a case worth a nicer answer, and returning a
        // name that is taken would be a write over somebody's file.
        return numbered(name, Int(Date().timeIntervalSince1970))
    }

    static func numbered(_ name: String, _ number: Int) -> String {
        let parts = parted(name)
        guard !parts.ext.isEmpty else { return "\(name)-\(number)" }
        return "\(parts.stem)-\(number).\(parts.ext)"
    }

    // MARK: - How far it has got

    /// A count of bytes, in the units the platform writes them in: decimal, because that is what
    /// Finder and every browser show, rather than the binary ones a terminal shows.
    ///
    /// Its own arithmetic rather than `ByteCountFormatter`, because that formatter is localised
    /// and its output has changed between releases, and this is a line the suite pins.
    public static func size(_ bytes: Int64) -> String {
        guard bytes >= 1_000 else { return "\(max(bytes, 0)) bytes" }

        var value = Double(bytes)
        var units = ["kB", "MB", "GB", "TB"].makeIterator()
        var unit = "kB"
        while value >= 1_000, let next = units.next() {
            value /= 1_000
            unit = next
        }
        // `String(format:)` with no locale is not localised, so the separator is a full stop
        // wherever this runs, which is what the suite asserts against.
        return String(format: "%.1f %@", value, unit)
    }

    /// The line under a download that is still arriving.
    ///
    /// A server that sends no `Content-Length` is common enough on a dev server to be worth
    /// handling rather than showing "of 0 bytes": what is known is how much has arrived, so that
    /// is all it says.
    public static func progress(received: Int64, expected: Int64) -> String {
        guard expected > 0 else { return size(received) }
        return "\(size(received)) of \(size(expected))"
    }
}
