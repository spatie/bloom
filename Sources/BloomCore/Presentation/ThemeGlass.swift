import Foundation

public enum ThemeGlass: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, thin, regular, thick

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public func tintOpacity(maximum: Double = 0.4) -> Double {
        let maximum = min(max(maximum, 0), 1)
        switch self {
        case .off: return 1
        case .thin: return maximum / 4
        case .regular: return maximum / 2
        case .thick: return maximum
        }
    }
}
