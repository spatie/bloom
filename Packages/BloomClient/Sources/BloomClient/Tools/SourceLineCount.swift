import Foundation

public enum SourceLineCount {
    public static func count(_ contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        var count = contents.reduce(into: 0) { total, character in
            if character == "\n" { total += 1 }
        }
        // A file whose last line has no newline still has that line.
        if contents.hasSuffix("\n") == false { count += 1 }
        return count
    }
}
