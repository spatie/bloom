import Foundation

/// The conversation column and its independent prose measure. Wide content always gets the
/// column; limiting paragraphs must never narrow a table, fence or command result with them.
public enum ChatWidth: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case wide
    case full

    public static let defaultsKey = "chat.width"
    public static let limitsProseKey = "chat.limitsProse"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .comfortable: "Comfortable"
        case .wide: "Wide"
        case .full: "Full"
        }
    }

    public struct Measures: Equatable, Sendable {
        public var conversation: Double
        public var prose: Double

        public init(conversation: Double, prose: Double) {
            self.conversation = conversation
            self.prose = prose
        }
    }

    public func measures(limitsProse: Bool = true) -> Measures {
        let conversation: Double = switch self {
        case .comfortable: 760
        case .wide: 1100
        case .full: .infinity
        }
        let prose: Double = switch self {
        case .comfortable: 680
        case .wide, .full: 960
        }
        return Measures(conversation: conversation, prose: limitsProse ? prose : .infinity)
    }

    public static func read(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .comfortable
    }
}
