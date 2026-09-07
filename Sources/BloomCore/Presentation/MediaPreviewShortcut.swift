/// Bare Space belongs to Quick Look only over an image. Modified presses and repeats retain
/// their normal meaning, and a save sheet must never open a preview behind itself.
public enum MediaPreviewShortcut {
    public static func opens(
        keyCode: UInt16,
        hasModifiers: Bool,
        isRepeat: Bool,
        isOverImage: Bool,
        hasSheet: Bool
    ) -> Bool {
        keyCode == 49 && !hasModifiers && !isRepeat && isOverImage && !hasSheet
    }
}
