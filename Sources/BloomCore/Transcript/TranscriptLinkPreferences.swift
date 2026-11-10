import Foundation

/// Extra transcript schemes are opt-in. The same normalisation is used for settings, scanning,
/// and the final opening check so a saved value cannot bypass the reserved schemes.
public struct TranscriptLinkPreferences: Sendable {
    public static let key = "transcript.allowedAppLinkSchemes"
    public static let suggestions = ["linear", "slack", "figma", "notion", "zoommtg"]

    public static func schemes(in value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
            .compactMap { additionalScheme(String($0)) })
    }

    public static func additionalScheme(_ value: String) -> String? {
        let scheme = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = scheme.utf8.first, (97...122).contains(first),
              scheme.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46].contains($0) }),
              scheme != "file", scheme != "javascript",
              scheme != "bloom", scheme != "bloomdev", !scheme.hasPrefix("bloom-") else { return nil }
        return scheme
    }
}
