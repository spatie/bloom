import Foundation
import Testing

/// Holds `actual` against `Tests/fixtures/characterisation/<name>`, byte for byte. The suite never
/// writes a fixture: a mismatch prints the text JSON encoded on a `BLOOM-FIXTURE` line instead,
/// so whitespace survives a CI log.
func expectCharacterised(
    _ actual: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let path = "characterisation/\(name)"
    let expected = bloomFixtureURL(path).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    guard actual != expected else { return }

    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let encoded = (try? encoder.encode(actual)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    let problem = expected == nil ? "is missing" : "differs"
    Issue.record(
        Comment(rawValue: "Fixture \(path) \(problem).\nBLOOM-FIXTURE \(path) \(encoded)"),
        sourceLocation: sourceLocation
    )
}
