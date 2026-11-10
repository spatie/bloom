import Foundation

extension TerminalCommandRun {
    /// A recording is a stream, not a screenshot: progress redraws and terminal controls must not
    /// become hundreds of apparent lines of evidence in the model's context.
    public static func clean(_ recording: String, lineLimit: Int = 400) -> String {
        let scalars = Array(recording.unicodeScalars)
        var lines: [String] = []
        var segment = String.UnicodeScalarView()
        var previous = ""
        var index = 0
        func finishLine() {
            lines.append(segment.isEmpty ? previous : String(segment))
            segment = String.UnicodeScalarView()
            previous = ""
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x1B:
                guard index < scalars.count else { continue }
                let introducer = scalars[index].value
                index += 1
                if introducer == 0x5B { // CSI ends at its final byte.
                    while index < scalars.count {
                        let byte = scalars[index].value
                        index += 1
                        if (0x40...0x7E).contains(byte) { break }
                    }
                } else if [0x5D, 0x50, 0x5E, 0x5F, 0x58].contains(introducer) {
                    // OSC and string controls end at BEL or ST, including hyperlink metadata.
                    while index < scalars.count {
                        let byte = scalars[index].value
                        index += 1
                        if byte == 7 || byte == 0x9C { break }
                        if byte == 0x1B, index < scalars.count, scalars[index].value == 0x5C {
                            index += 1
                            break
                        }
                    }
                } else if (0x20...0x2F).contains(introducer) {
                    while index < scalars.count, (0x20...0x2F).contains(scalars[index].value) { index += 1 }
                    if index < scalars.count { index += 1 }
                }
            case 13:
                if !segment.isEmpty { previous = String(segment) }
                segment = String.UnicodeScalarView()
            case 10: finishLine()
            case 8:
                // Work in Characters so backspace also removes a complete non-ASCII glyph.
                var text = String(segment)
                if !text.isEmpty { text.removeLast() }
                segment = text.unicodeScalars
            case 0...31 where scalar.value != 9: continue
            case 0x7F...0x9F: continue
            default: segment.append(scalar)
            }
        }
        finishLine()
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let trimmed = lines[first...last]
        let limit = max(1, lineLimit)
        let omitted = max(0, trimmed.count - limit)
        return (omitted > 0 ? "(\(omitted) earlier lines left out)\n" : "")
            + trimmed.suffix(limit).joined(separator: "\n")
    }
}
