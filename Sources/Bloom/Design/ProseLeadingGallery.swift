import SwiftUI
import BloomCore

/// What the conversation's line height is at every step of `ChatTextSize`, before and after it
/// stopped being a constant, and what the five steps of `ChatLineHeight` do to it.
///
/// The owner put an agent's generated HTML page next to Bloom's transcript and asked for the
/// page's line height in the chat. The page was set at about 1.7 and the transcript at three fixed
/// points on top of the font's own line box, which is 1.46 at the default and 1.30 at the largest
/// step: the setting that exists to make the conversation easier to read was tightening it. This
/// page is that comparison, at every size at once, because "about 1.7" is not a thing anybody can
/// judge from one paragraph.
///
/// The right hand column of each pair is the real modifier reading a real environment, so the page
/// cannot drift from what the transcript does: `.proseLeading()` resolves the rung against
/// `\.fontScale`, `\.chatFont` and `\.chatLineHeight` exactly as `ProseRowView` does.
///
/// The last column is the setting the owner then asked for, at one text size, because the question
/// there is a different one: not whether the ratio holds across the sizes but whether a reader can
/// tell one step from the next. A picker whose middle segments look alike is a control that does
/// nothing, and this is where that is judged rather than argued.
///
///     Bloom --snapshot-gallery <dir> --gallery prose-leading
///
/// Change `ChatFont.standard` in the page below to look at the same thing in another face.
struct ProseLeadingGallery: View {
    /// A paragraph with a filename in it, which is the shape of most transcript prose: sentences
    /// wrapped around something set in the mono face. Deliberately no link in it, because
    /// `MarkdownView` draws a run holding one with an `NSViewRepresentable` and the offscreen
    /// renderer paints a yellow placeholder over those. See `Snapshot`.
    private static let sample = """
    Ran the suite and the failure is real. `DiffParser.parse(hunk:)` drops the last line of a \
    hunk whose header has no trailing count, which is every single-line hunk `git` writes.
    """

    /// What the transcript used to add, in points, whatever size it was set at. Here so the page
    /// can draw the thing that was wrong beside the thing that replaced it.
    private static let wasFixed: CGFloat = 3

    /// The command in the permission panel, wrapped, which is the one block `codeLeading` is for.
    private static let command =
        "rm -rf node_modules && npm ci --prefer-offline && npm run build -- --mode production"

    private static let paneWidth: CGFloat = 340

    private let face = ChatFont.standard

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            column("Prose, three fixed points") { size in
                prose(leading: Self.wasFixed)
                    .environment(\.fontScale, size.scale)
            }
            column("Prose, 1.7 of the size") { size in
                prose()
                    .environment(\.fontScale, size.scale)
            }
            column("Command, 1.3 of its line box") { size in
                commandBlock()
                    .environment(\.fontScale, size.scale)
            }
            lineHeightColumn()
        }
        .environment(\.chatFont, face)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One column: the same drawing at each of the five steps, labelled with the step and with
    /// the point size the body rung comes out at, because the step's name says nothing about that.
    private func column<Each: View>(
        _ title: String, @ViewBuilder each: @escaping (ChatTextSize) -> Each
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            ForEach(ChatTextSize.allCases) { size in
                VStack(alignment: .leading, spacing: 6) {
                    Text(caption(for: size))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                    each(size)
                }
            }
        }
        .frame(width: Self.paneWidth, alignment: .leading)
    }

    /// The same five drawings at the default text size, one per step of the line height setting.
    /// One size, because the axis this column is about is the other one.
    private func lineHeightColumn() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Prose, the five line-height steps")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            ForEach(ChatLineHeight.allCases) { step in
                VStack(alignment: .leading, spacing: 6) {
                    Text(caption(for: step))
                        .font(Typo.micro)
                        .foregroundStyle(Palette.textTertiary)
                    prose()
                        .environment(\.fontScale, ChatTextSize.standard.scale)
                        .environment(\.chatLineHeight, step)
                }
            }
        }
        .frame(width: Self.paneWidth, alignment: .leading)
    }

    /// The step's name and the leading it resolves to, so the numbers in the report can be read
    /// off the picture rather than trusted.
    private func caption(for size: ChatTextSize) -> String {
        let leading = TranscriptLayout.proseLeading(
            Typo.body, scale: size.scale, face: face, lineHeight: .standard
        )
        return "\(size.title), prose +\(Int(leading))pt"
    }

    /// The same line for the other axis: the step, its ratio, and the points it comes to at the
    /// default text size.
    private func caption(for step: ChatLineHeight) -> String {
        let leading = TranscriptLayout.proseLeading(
            Typo.body, scale: ChatTextSize.standard.scale, face: face, lineHeight: step
        )
        return "\(step.title), \(step.ratio) of the size, prose +\(Int(leading))pt"
    }

    /// `ProseRowView`'s own drawing, minus the row's padding, which is not what this page is about.
    /// The leading is the real modifier unless a number is handed in.
    @ViewBuilder
    private func prose(leading: CGFloat? = nil) -> some View {
        let block = MarkdownView(Self.sample)
            .font(Typo.body)
            .frame(maxWidth: .infinity, alignment: .leading)

        if let leading {
            block.lineSpacing(leading)
        } else {
            block.proseLeading()
        }
    }

    /// The permission panel's command, at the rung and on the ground the panel draws it on.
    private func commandBlock() -> some View {
        CommandSample(text: Self.command)
    }
}

/// The command block on its own, because the leading it takes has to be read out of the
/// environment and a `@ViewBuilder` method cannot hold an `@Environment`.
private struct CommandSample: View {
    let text: String

    @Environment(\.fontScale) private var fontScale
    @Environment(\.chatFont) private var chatFont

    var body: some View {
        Text(text)
            .font(Typo.codeSmall)
            .foregroundStyle(Palette.textPrimary)
            .lineSpacing(TranscriptLayout.codeLeading(
                Typo.codeSmall, scale: fontScale, face: chatFont
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.spacing)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(Palette.surfaceSunken)
            )
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Four columns of five, tall rather than wide, because the question is what happens ACROSS
    /// the range of text sizes and that only reads if they are stacked. The fourth column is the
    /// other axis, the line height setting, at one size.
    static let proseLeading = Gallery(
        name: "prose-leading",
        title: "Line height across the chat text sizes and the line-height steps",
        size: CGSize(width: 1_560, height: 1_320),
        needsFocus: false,
        view: { _ in AnyView(ProseLeadingGallery()) }
    )
}
