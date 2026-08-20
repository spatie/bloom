import SwiftUI

/// Says whether a one line label is being cut off, and only while somebody is asking.
///
/// SwiftUI never reports that a `Text` truncated. The only honest way to find out is to lay the
/// same string out with nothing capping its width and compare that with the width it was actually
/// drawn in, and that is a second text layout of every string it is asked about.
///
/// A second text layout per row is exactly the cost the transcript has just spent taking off the
/// path between clicking a workspace and seeing it, so this one is built only while `isActive`,
/// which is the one row under the pointer rather than the four hundred the list has realised.
/// Nothing is measured, and no state is written, for a row nobody is pointing at.
///
/// The ruler goes in a `background`, which is laid out against the content and proposes nothing to
/// it, so putting one behind a label cannot change where the label sits. `hidden()` rather than
/// `opacity(0)`: both are invisible, and only `hidden` promises the layout is still done, which is
/// the entire point of drawing it.
struct TruncationProbe: ViewModifier {
    /// The same string the content is drawing.
    var text: String
    /// And the same rung, resolved through the same environment, so the ruler measures the face
    /// the row is set in rather than the one this file happens to name.
    var font: ScaledFont
    /// Whether anybody wants the answer. False for every row except the hovered one.
    var isActive: Bool
    @Binding var isTruncated: Bool

    /// What the label was drawn in, and what it would have taken. Both nil until measured, so a
    /// half measured probe never claims anything.
    @State private var drawn: CGFloat?
    @State private var whole: CGFloat?

    func body(content: Content) -> some View {
        content
            .background { given }
            .background(alignment: .leading) { ruler }
            .onChange(of: isActive) { _, active in
                guard !active else { return }
                drawn = nil
                whole = nil
                isTruncated = false
            }
    }

    /// What the label was actually given. A background is sized to the content, so this is the
    /// content's own width, read without a frame behind every row in the list.
    @ViewBuilder
    private var given: some View {
        if isActive {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    drawn = $0
                    report()
                }
        }
    }

    /// And what it wanted. `fixedSize` is proposed nothing, so what comes back is the width of the
    /// string rather than the width of the row, and it overflows this layer rather than being
    /// clamped by it.
    ///
    /// Its own background rather than a second view in the first one. In a `ZStack` with the ruler
    /// the stack takes the WIDER of the two, and `Color.clear` then fills the stack rather than the
    /// content: measured here, a 176 point label column reported 195.5 against a string that wanted
    /// 195.5, so the one case this exists to catch was the one case it always called false. Two
    /// layers cannot do that to each other: neither is ever sized to the other, and a background
    /// never changes the size of what it is behind.
    @ViewBuilder
    private var ruler: some View {
        if isActive {
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    whole = $0
                    report()
                }
        }
    }

    /// Half a point of slack, because the two numbers come from two layout passes of the same
    /// string and a label that fits exactly is not truncated.
    private func report() {
        guard isActive, let drawn, let whole, drawn > 0 else { return }
        let cut = whole > drawn + 0.5
        if cut != isTruncated { isTruncated = cut }
    }
}

extension View {
    /// Reports whether this one line label is being cut off, measured only while `isActive`.
    func reportsTruncation(
        of text: String,
        font: ScaledFont,
        isActive: Bool,
        into isTruncated: Binding<Bool>
    ) -> some View {
        modifier(
            TruncationProbe(text: text, font: font, isActive: isActive, isTruncated: isTruncated)
        )
    }
}
