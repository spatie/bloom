import Foundation

#if canImport(os)
import os
typealias CoreLogger = Logger
#else
/// Linux services log to stderr for systemd or their container runtime. Keep the same privacy
/// defaults as OSLog, so porting a log statement cannot reveal an unmarked interpolated value.
struct CoreLogger: Sendable {
    private let category: String

    init(subsystem: String, category: String) { self.category = category }

    func info(_ message: CoreLogMessage) { write("info", message) }
    func error(_ message: CoreLogMessage) { write("error", message) }

    private func write(_ level: String, _ message: CoreLogMessage) {
        let text = "[\(category)] \(level): \(message.text)\n"
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}

struct CoreLogMessage: ExpressibleByStringInterpolation, Sendable {
    var text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    enum Privacy { case `public`, `private` }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<Value>(_ value: Value, privacy: Privacy = .private) {
            text += privacy == .public ? String(describing: value) : "<private>"
        }
    }
}
#endif
