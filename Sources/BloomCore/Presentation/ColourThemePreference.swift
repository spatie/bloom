import Foundation
import Observation

@MainActor
@Observable
public final class ColourThemePreference {
    public static let shared = ColourThemePreference()
    private static let overridesKey = "themeOverrides"
    @ObservationIgnored private let defaults: UserDefaults

    public var choice: ColourTheme {
        didSet { defaults.set(choice.id, forKey: ColourTheme.defaultsKey) }
    }
    private var saved: [String: ThemeOverrides]

    public var overrides: ThemeOverrides {
        get { saved[choice.id] ?? ThemeOverrides() }
        set {
            saved[choice.id] = newValue
            persist()
        }
    }

    public var glassOverride: ThemeGlass? {
        get { overrides.glass }
        set { overrides.glass = newValue }
    }
    public var glass: ThemeGlass { glassOverride ?? choice.glass }
    public var codeScheme: CodeScheme { overrides.codeScheme(for: choice) }
    public var terminalScheme: TerminalScheme { overrides.terminalScheme(for: choice) }
    public var terminalSource: TerminalSource { overrides.terminalSource ?? .builtin(choice.terminalScheme) }
    public var followsGhostty: Bool { terminalSource == .ghostty }
    public var codeTypography: ThemeTypography { overrides.codeTypography.inheriting(choice.codeTypography) }
    public var terminalTypography: ThemeTypography { overrides.terminalTypography.inheriting(choice.terminalTypography) }
    public var chatFont: String {
        get { overrides.chatFont ?? choice.chatFont }
        set { overrides.chatFont = ChatFontCatalogue.canonicalID(newValue) }
    }
    public var chatTextSize: ChatTextSize {
        get { overrides.chatTextSize ?? choice.chatTextSize }
        set { overrides.chatTextSize = newValue }
    }
    public var chatLineHeight: ChatLineHeight {
        get { overrides.chatLineHeight ?? choice.chatLineHeight }
        set { overrides.chatLineHeight = newValue }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialChoice = ColourTheme(storedValue: defaults.string(forKey: ColourTheme.defaultsKey))
        choice = initialChoice
        if let data = defaults.data(forKey: Self.overridesKey) {
            do {
                saved = try ThemeOverrides.Archive.decode(data).themes
            } catch {
                saved = [initialChoice.id: ThemeOverrides.migrating(from: defaults, theme: initialChoice)]
                defaults.set(data, forKey: "themeOverrides.unreadableBackup")
                NSLog("Could not read theme settings: %@", error.localizedDescription)
            }
        } else {
            saved = [initialChoice.id: ThemeOverrides.migrating(from: defaults, theme: initialChoice)]
            persist()
        }
    }

    public func restoreDefaults() {
        saved.removeValue(forKey: choice.id)
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(ThemeOverrides.Archive(themes: saved))
            defaults.set(data, forKey: Self.overridesKey)
        } catch {
            NSLog("Could not save theme settings: %@", error.localizedDescription)
        }
    }
}
