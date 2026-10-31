import AppKit
import BloomCore

/// The system's blur over a chat's transcript while a file is being dragged towards its composer.
///
/// An `NSVisualEffectView` among the transcript's siblings rather than a SwiftUI material over it.
/// The transcript is an `NSTableView`, and a SwiftUI material only blurs what SwiftUI itself drew
/// beneath it, so over this view it came out as a flat tint. A visual effect view in the same
/// AppKit hierarchy blurs whatever is behind it in the window, which is the whole conversation
/// area, behind the composer too. The composer is a SwiftUI sibling drawn above and stays sharp.
///
/// Made on first use and only shown for the length of a drag, so a transcript that is never dragged
/// over pays for nothing.
@MainActor
enum TranscriptBlur {
    /// Each pane's hold view and the chat it is showing now. The pane is reused across chats, so
    /// the chat is written again on every update rather than once on creation.
    private static let sessions = NSMapTable<TranscriptHoldView, NSString>.weakToStrongObjects()
    private static let veils = NSMapTable<TranscriptHoldView, NSVisualEffectView>.weakToWeakObjects()

    /// Translucent enough that the colours and shapes of the conversation come through the blur.
    /// `.sheet` is the background of a sheet and is close to opaque, which over the main chat's solid
    /// ground hid the transcript completely.
    private static let material = NSVisualEffectView.Material.popover

    static func register(_ hold: TranscriptHoldView, showing session: SessionID) {
        sessions.setObject(session.rawValue as NSString, forKey: hold)
    }

    /// Blurs the transcripts of the chats in `keys` and clears every other. Called when the answer
    /// changes, so it runs twice per drag.
    static func apply(to keys: Set<String>) {
        for case let hold as TranscriptHoldView in sessions.keyEnumerator() {
            let isBlurred = (sessions.object(forKey: hold) as String?).map(keys.contains) ?? false
            guard let veil = veil(for: hold, creating: isBlurred) else { continue }
            veil.isHidden = !isBlurred
        }
    }

    private static func veil(for hold: TranscriptHoldView, creating: Bool) -> NSVisualEffectView? {
        if let existing = veils.object(forKey: hold) { return existing }
        guard creating else { return nil }

        let veil = NSVisualEffectView()
        veil.material = material
        veil.blendingMode = .withinWindow
        veil.state = .active
        veil.isHidden = true
        veil.translatesAutoresizingMaskIntoConstraints = false
        hold.addSubview(veil, positioned: .above, relativeTo: hold.scroll)
        NSLayoutConstraint.activate([
            veil.leadingAnchor.constraint(equalTo: hold.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: hold.trailingAnchor),
            veil.topAnchor.constraint(equalTo: hold.topAnchor),
            veil.bottomAnchor.constraint(equalTo: hold.bottomAnchor),
        ])
        veils.setObject(veil, forKey: hold)
        return veil
    }
}
