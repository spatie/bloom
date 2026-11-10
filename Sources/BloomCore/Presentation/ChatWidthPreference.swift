import Foundation
import Observation

@MainActor
@Observable
public final class ChatWidthPreference {
    public static let shared = ChatWidthPreference()
    @ObservationIgnored private let defaults: UserDefaults

    public var choice: ChatWidth {
        didSet { defaults.set(choice.rawValue, forKey: ChatWidth.defaultsKey) }
    }
    public var limitsProse: Bool {
        didSet { defaults.set(limitsProse, forKey: ChatWidth.limitsProseKey) }
    }
    public var measures: ChatWidth.Measures { choice.measures(limitsProse: limitsProse) }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = ChatWidth.read(from: defaults)
        limitsProse = defaults.object(forKey: ChatWidth.limitsProseKey) as? Bool ?? true
    }
}
