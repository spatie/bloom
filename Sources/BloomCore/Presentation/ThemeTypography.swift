import Foundation

public struct ThemeTypography: Codable, Hashable, Sendable {
    public var fontFamily: String?
    public var fontSize: Double?
    public var lineHeight: Double?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, lineHeight: Double? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    public func inheriting(_ defaults: Self) -> Self {
        Self(fontFamily: fontFamily ?? defaults.fontFamily,
             fontSize: Self.clamped(fontSize ?? defaults.fontSize, to: 9...28),
             lineHeight: Self.clamped(lineHeight ?? defaults.lineHeight, to: 1...2))
    }

    private static func clamped(_ value: Double?, to range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
