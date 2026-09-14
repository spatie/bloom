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

    /// The selected preset's glass and colour schemes, as changed while it was selected.
    public var overrides: ThemeOverrides {
        get { saved[choice.id] ?? ThemeOverrides() }
        set {
            saved[choice.id] = newValue
            persist()
        }
    }

    /// Fonts, sizes and line heights, which follow the person across presets.
    public var typographyOverrides: TypographyOverrides {
        didSet { persist() }
    }

    /// Whether terminals draw with the user's Ghostty configuration, laid over the selected
    /// preset's terminal scheme. One setting for every preset: a person's terminal is theirs
    /// whichever window colours they picked.
    public var followsGhostty: Bool {
        didSet { persist() }
    }

    public var glassOverride: ThemeGlass? {
        get { overrides.glass }
        set { overrides.glass = newValue }
    }
    public var glass: ThemeGlass { glassOverride ?? choice.glass }
    public var codeScheme: CodeScheme { overrides.codeScheme(for: choice) }
    public var terminalScheme: TerminalScheme { overrides.terminalScheme(for: choice) }
    public var codeTypography: ThemeTypography { typographyOverrides.codeTypography.inheriting(choice.codeTypography) }
    public var terminalTypography: ThemeTypography {
        typographyOverrides.terminalTypography.inheriting(choice.terminalTypography)
    }
    public var chatFont: String {
        get { typographyOverrides.chatFont ?? choice.chatFont }
        set { typographyOverrides.chatFont = ChatFontCatalogue.canonicalID(newValue) }
    }
    public var chatTextSize: ChatTextSize {
        get { typographyOverrides.chatTextSize ?? choice.chatTextSize }
        set { typographyOverrides.chatTextSize = newValue }
    }
    public var chatLineHeight: ChatLineHeight {
        get { typographyOverrides.chatLineHeight ?? choice.chatLineHeight }
        set { typographyOverrides.chatLineHeight = newValue }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initialChoice = ColourTheme(storedValue: defaults.string(forKey: ColourTheme.defaultsKey))
        choice = initialChoice
        if let data = defaults.data(forKey: Self.overridesKey) {
            do {
                let archive = try ThemeOverrides.Archive.decode(data)
                followsGhostty = ThemeOverrides.followsGhostty(migrating: archive, from: defaults)
                saved = archive.themes.mapValues { theme in
                    var theme = theme
                    if theme.terminalSource == .ghostty { theme.terminalSource = nil }
                    return theme
                }
                typographyOverrides = archive.typography ?? .migrating(from: defaults, theme: initialChoice)
            } catch {
                followsGhostty = ThemeOverrides.followsGhostty(migrating: nil, from: defaults)
                saved = [initialChoice.id: ThemeOverrides.migrating(from: defaults, theme: initialChoice)]
                typographyOverrides = .migrating(from: defaults, theme: initialChoice)
                defaults.set(data, forKey: "themeOverrides.unreadableBackup")
                NSLog("Could not read theme settings: %@", error.localizedDescription)
            }
        } else {
            followsGhostty = ThemeOverrides.followsGhostty(migrating: nil, from: defaults)
            saved = [initialChoice.id: ThemeOverrides.migrating(from: defaults, theme: initialChoice)]
            typographyOverrides = .migrating(from: defaults, theme: initialChoice)
            persist()
        }
    }

    /// Puts the selected preset's glass and colours back. Typography is left alone, because it
    /// was never the preset's to restore.
    public func restoreDefaults() {
        saved.removeValue(forKey: choice.id)
        persist()
    }

    private func persist() {
        do {
            let archive = ThemeOverrides.Archive(
                themes: saved, typography: typographyOverrides, followsGhostty: followsGhostty
            )
            defaults.set(try JSONEncoder().encode(archive), forKey: Self.overridesKey)
        } catch {
            NSLog("Could not save theme settings: %@", error.localizedDescription)
        }
    }
}
