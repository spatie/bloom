import Foundation

/// The drawing commands in one SVG `d` attribute, normalised to absolute coordinates.
///
/// **Here rather than as an image file, because a mark has to be two things at once.** The usage
/// panel draws each provider's mark in the secondary ink beside its name, and the menu bar draws
/// the same mark as a template, black on clear, inside an image it renders itself. An SVG loaded
/// as an `NSImage` is a bitmap by the time either of those gets it. A path is a shape, which
/// SwiftUI fills in whatever style it is asked for and renders crisp at any scale.
///
/// A parser rather than hand-converted `addCurve` calls, so a mark can be replaced by pasting a
/// new `d` string, and so the parsing is something a test can hold. It reads the commands the
/// marks actually use (M, L, H, V, C, S, Q, T, Z, both cases) and stops at anything else, which is
/// arcs: none of the marks has one, and a half-read arc drawn as a straight line would be worse
/// than a mark that stops short.
public struct SVGPath: Sendable, Hashable {
    public enum Command: Sendable, Hashable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case quad(to: CGPoint, control: CGPoint)
        case close
    }

    public var commands: [Command]

    /// The smallest rectangle holding every point the commands name, controls included. Close
    /// enough to the drawn bounds for centring a mark, which is all it is used for.
    public var bounds: CGRect {
        var points: [CGPoint] = []
        for command in commands {
            switch command {
            case .move(let point), .line(let point): points.append(point)
            case .curve(let to, let first, let second): points += [to, first, second]
            case .quad(let to, let control): points += [to, control]
            case .close: break
            }
        }
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public init(commands: [Command]) {
        self.commands = commands
    }

    public init(_ data: String) {
        var reader = Reader(Array(data.utf8))
        commands = reader.read()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var commands: [Command] = []

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read() -> [Command] {
            var command: UInt8 = 0
            while true {
                skipSeparators()
                guard index < bytes.count else { break }
                let byte = bytes[index]
                if Self.isCommand(byte) {
                    command = byte
                    index += 1
                    if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                        commands.append(.close)
                        current = subpathStart
                        lastCubicControl = nil
                        lastQuadControl = nil
                        continue
                    }
                } else if command == 0 || !Self.startsNumber(byte) {
                    break
                }
                guard apply(command) else { break }
                // A move followed by more pairs is an implicit line, per the spec.
                if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
                if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
            }
            return commands
        }

        mutating func apply(_ command: UInt8) -> Bool {
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let point = point(from: origin) else { return false }
                commands.append(.move(point))
                current = point
                subpathStart = point
                lastCubicControl = nil
                lastQuadControl = nil
            case UInt8(ascii: "l"):
                guard let point = point(from: origin) else { return false }
                line(to: point)
            case UInt8(ascii: "h"):
                guard let x = number() else { return false }
                line(to: CGPoint(x: relative ? current.x + x : x, y: current.y))
            case UInt8(ascii: "v"):
                guard let y = number() else { return false }
                line(to: CGPoint(x: current.x, y: relative ? current.y + y : y))
            case UInt8(ascii: "c"):
                guard let first = point(from: origin), let second = point(from: origin),
                      let end = point(from: origin) else { return false }
                curve(to: end, first, second)
            case UInt8(ascii: "s"):
                guard let second = point(from: origin), let end = point(from: origin) else { return false }
                let first = lastCubicControl.map { reflect($0) } ?? current
                curve(to: end, first, second)
            case UInt8(ascii: "q"):
                guard let control = point(from: origin), let end = point(from: origin) else { return false }
                quad(to: end, control)
            case UInt8(ascii: "t"):
                guard let end = point(from: origin) else { return false }
                quad(to: end, lastQuadControl.map { reflect($0) } ?? current)
            default:
                return false
            }
            return true
        }

        mutating func line(to point: CGPoint) {
            commands.append(.line(point))
            current = point
            lastCubicControl = nil
            lastQuadControl = nil
        }

        mutating func curve(to end: CGPoint, _ first: CGPoint, _ second: CGPoint) {
            commands.append(.curve(to: end, control1: first, control2: second))
            current = end
            lastCubicControl = second
            lastQuadControl = nil
        }

        mutating func quad(to end: CGPoint, _ control: CGPoint) {
            commands.append(.quad(to: end, control: control))
            current = end
            lastQuadControl = control
            lastCubicControl = nil
        }

        func reflect(_ control: CGPoint) -> CGPoint {
            CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        mutating func point(from origin: CGPoint) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: origin.x + x, y: origin.y + y)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                index += 1
            }
            var sawDot = false
            var sawExponent = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    index += 1
                } else if byte == UInt8(ascii: "."), !sawDot, !sawExponent {
                    sawDot = true
                    index += 1
                } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E"), !sawExponent {
                    sawExponent = true
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                        index += 1
                    }
                } else {
                    break
                }
            }
            guard index > start,
                  let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  let value = Double(text)
            else {
                index = start
                return nil
            }
            return CGFloat(value)
        }

        mutating func skipSeparators() {
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == 0x0A
                    || byte == 0x0D || byte == 0x09 else { return }
                index += 1
            }
        }

        static func isCommand(_ byte: UInt8) -> Bool {
            let lower = byte | 0x20
            return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z") && lower != UInt8(ascii: "e")
        }

        static func startsNumber(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
        }
    }
}
