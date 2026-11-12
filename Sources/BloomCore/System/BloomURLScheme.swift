import Foundation

/// The URL schemes this copy of Bloom answers to, read off its own bundle rather than written out.
///
/// It was the literal `"bloom"` inside `BloomDeepLink`, and `Tools/dev-build.sh` rebrands the
/// registered scheme to `bloomdev` so the dev copy cannot swallow a link meant for the real one.
/// The result was a dev build that registered `bloomdev://`, received them, and then refused every
/// one with "The link must include a prompt and project path", which is not what was wrong with
/// it. Reading `CFBundleURLTypes` means the check can only ever disagree with LaunchServices if the
/// plist does.
///
/// It moved into the core when the transcript started drawing workspace links, because which
/// scheme is this copy's own is now also a rule about which links a chat may open, and the bridge
/// writes the same scheme into the links it hands an agent.
public enum BloomURLScheme {
    /// Lower case, as `BloomLinkRequest` compares them.
    public static let own: Set<String> = registered(in: Bundle.main.infoDictionary)

    /// The scheme a link this copy writes uses: `bloom` when it is registered, which is every
    /// shipped build, and otherwise whichever this copy has, which for the dev build is `bloomdev`.
    public static var primary: String { primary(of: own) }

    static func registered(in info: [String: Any]?) -> Set<String> {
        let types = info?["CFBundleURLTypes"] as? [[String: Any]]
        let registered = (types ?? [])
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .map { $0.lowercased() }

        // A bundle with no URL types is `swift run` or a test host. Falling back to the shipped
        // scheme keeps those working rather than making every link fail in a way that reads as a
        // malformed link.
        return registered.isEmpty ? ["bloom"] : Set(registered)
    }

    static func primary(of schemes: Set<String>) -> String {
        schemes.contains("bloom") ? "bloom" : schemes.min() ?? "bloom"
    }
}
