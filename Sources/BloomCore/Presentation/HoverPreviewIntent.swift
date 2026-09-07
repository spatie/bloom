/// Hover + Space is deliberate; continuing to type with the pointer resting on a file is not.
/// Any other key disarms preview until the pointer moves again, without moving editor focus.
public struct HoverPreviewIntent {
    private var isArmed = true

    public init() {}

    public mutating func keyPressed(
        keyCode: UInt16,
        hasModifiers: Bool,
        isRepeat: Bool,
        pointerMoved: Bool,
        isOverFile: Bool,
        hasSheet: Bool
    ) -> Bool {
        if pointerMoved { isArmed = true }
        guard keyCode == 49, !hasModifiers else { isArmed = false; return false }
        return isArmed && !isRepeat && isOverFile && !hasSheet
    }
}
