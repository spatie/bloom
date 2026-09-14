import Foundation

/// A tab's layout size is independent of the space available to display it. Scaling the preview
/// must not change CSS breakpoints, and toggling it off must not discard the chosen dimensions.
public struct BrowserViewport: Equatable, Sendable {
    public static let limits = 240...3840
    public var isEnabled = false
    public var fitsPane = true
    public private(set) var width = 390
    public private(set) var height = 844
    public private(set) var savedSizes: [Size] = []

    public struct Size: Hashable, Sendable {
        public let width: Int
        public let height: Int
    }

    public var canSaveSize: Bool {
        preset == nil && !savedSizes.contains(Size(width: width, height: height))
    }

    public mutating func saveSize() {
        guard canSaveSize else { return }
        savedSizes.append(Size(width: width, height: height))
    }

    public mutating func removeSavedSizes() { savedSizes.removeAll() }

    public init() {}

    public mutating func resize(width: Int, height: Int) {
        self.width = min(max(width, Self.limits.lowerBound), Self.limits.upperBound)
        self.height = min(max(height, Self.limits.lowerBound), Self.limits.upperBound)
    }

    public mutating func rotate() {
        resize(width: height, height: width)
    }

    public func scale(availableWidth: Double, availableHeight: Double) -> Double {
        guard isEnabled, fitsPane else { return 1 }
        return max(0.01, min(1, availableWidth / Double(width), availableHeight / Double(height)))
    }

    public var preset: Preset? {
        Preset.allCases.first { $0.width == width && $0.height == height }
    }

    public mutating func select(_ preset: Preset) {
        resize(width: preset.width, height: preset.height)
    }

    public enum Preset: String, CaseIterable, Sendable {
        case smallPhone = "Small phone"
        case phone = "Phone"
        case tablet = "Tablet"
        case laptop = "Laptop"
        case desktop = "Desktop"

        public var width: Int {
            switch self {
            case .smallPhone: 320
            case .phone: 390
            case .tablet: 768
            case .laptop: 1280
            case .desktop: 1440
            }
        }

        public var height: Int {
            switch self {
            case .smallPhone: 568
            case .phone: 844
            case .tablet: 1024
            case .laptop, .desktop: 900
            }
        }
    }
}
