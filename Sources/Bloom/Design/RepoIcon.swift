import SwiftUI
import AppKit
import BloomCore

/// The mark that stands for a project: its colour, with its initials on it.
///
/// One view, because this mark had already been drawn three different ways in four places, and a
/// project that is a circle in the toolbar and a square in the sidebar reads as two projects.
/// Everywhere a project is named without room for the whole name goes through here: the sidebar
/// section header, a row on Home, a search result and the toolbar title.
///
/// The letters come from `RepoMonogram`, which is in the core and unit tested, so the rule that
/// decides what `there-there` looks like is not something only a screenshot can answer.
///
/// Deliberately not something fetched. See `RepoMonogram` for why a repository avatar was not
/// worth the asynchrony: the mark has to be right on the first frame of the sidebar, offline, for
/// a folder that may have no remote at all.
///
/// A project that turned out to have artwork of its own on disk is drawn with it instead. That is
/// a file `RepoIconDetector` picked when the project was added, opened once per launch by
/// `RepoIconArt`, and it changes nothing above: the monogram is still what a project without one
/// gets, still what a project whose file has gone falls back to, and still the only thing a search
/// hit for a removed project can be drawn with.
struct RepoIcon: View {
    /// What the initials are taken from.
    var name: String
    /// The project's stored hex, or nil for a search hit whose project has gone.
    var accent: String?
    var size: CGFloat = Metrics.repoIcon
    /// The project's own artwork, when it has some and it could be read.
    var artwork: RepoArtwork?

    /// A selected row is filled with the accent colour, and a coloured tile on it is either
    /// invisible (a blue project on the blue bar) or a clash.
    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    /// The crossfade below is dropped rather than slowed when it is off, matching every other
    /// call site in the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(name: String, accent: String?, size: CGFloat = Metrics.repoIcon) {
        self.name = name
        self.accent = accent
        self.size = size
    }

    init(repo: Repo?, size: CGFloat = Metrics.repoIcon) {
        self.init(name: repo?.name ?? "", accent: repo?.accent, size: size)
        artwork = repo.flatMap(RepoIconArt.artwork(for:))
        artworkKey = repo?.hasIcon == true ? repo?.iconPath : nil
    }

    /// Which file is being drawn, or nil for the initials. What the crossfade below watches, and
    /// nothing else: `RepoArtwork` holds an `NSImage`, which is not a value and cannot be compared.
    private var artworkKey: String?

    /// Both marks are in the stack at once, so what changes is an opacity rather than a layout.
    /// The tile is a fixed square either way and neither branch has ever affected the row's
    /// height, but a mark that swapped by insertion could still flicker its clip shape.
    var body: some View {
        ZStack {
            monogram.opacity(artwork == nil ? 1 : 0)
            if let artwork { picture(artwork) }
        }
        // Only when the file behind the badge changes while this view is on screen, which is the
        // launch sweep answering (`AppModel+ProjectIcons`) and the settings window's three
        // buttons. A mark that is already artwork when it is first drawn has no change to
        // animate, so a launch fills the sidebar in one frame exactly as it always did.
        //
        // `Motion.arrival` rather than a curve of its own: a project's mark quietly becoming its
        // real icon is the same size of event as a row settling into a list, and the window has
        // one speed.
        .animation(reduceMotion ? nil : Motion.arrival, value: artworkKey)
    }

    /// The rounded tile every mark is cut to, so a found icon is the same shape as the letters it
    /// replaced and a row of projects reads as one row.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
    }

    /// Fitted rather than filled, so a mark that is not square is letterboxed inside the tile
    /// instead of having its ends cropped off. Clipped either way: artwork that is square and
    /// bigger than the tile has to end at the same rounded corner as everything else.
    private func picture(_ artwork: RepoArtwork) -> some View {
        Image(nsImage: artwork.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(shape)
            // Only around artwork that reaches the edges. It is what separates a pale icon from a
            // pale sidebar, and it is exactly what macOS draws around an app icon in a list. Around
            // a logo on transparency it would be a box drawn around nothing.
            .overlay {
                if artwork.isFullBleed {
                    shape.strokeBorder(borderInk, lineWidth: Metrics.hairline / 2)
                }
            }
            .accessibilityHidden(true)
    }

    private var borderInk: Color {
        isOnSelection ? Palette.selectedEmphasizedText.opacity(0.35) : Palette.textPrimary.opacity(0.15)
    }

    private var monogram: some View {
        shape
            .fill(fill)
            .overlay {
                Text(RepoMonogram.initials(for: name))
                    // A fraction of the tile rather than a rung of `Typo`. The rungs answer "how
                    // large is this text on the page", and this text is not on the page: it is
                    // artwork inside a fixed box, and a box that stayed 16 points while its
                    // letters followed a text size setting would overflow.
                    .font(.system(size: (size * 0.55).rounded(), weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    // A wide pair such as `WM` is squeezed rather than clipped or ellipsised.
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 1)
            }
            .frame(width: size, height: size)
            // The project's name is always written beside this, so VoiceOver reading the mark
            // would be reading the same word twice.
            .accessibilityHidden(true)
    }

    private var tint: Color {
        accent.map(Color.init(hexString:)) ?? Palette.textTertiary
    }

    /// On the emphasized selection the tile becomes the translucent white a `Chip` becomes there,
    /// which is what AppKit does to a coloured badge inside a selected table row. Derived from the
    /// environment rather than from the window's active state, for the reason `WorkspaceRow`
    /// gives: only the list itself knows when it is painting with the accent.
    private var fill: Color {
        isOnSelection ? Palette.selectedEmphasizedText.opacity(0.22) : tint
    }

    private var ink: Color {
        isOnSelection ? Palette.selectedEmphasizedText : contrastingInk
    }

    /// Black or white, whichever the tile's own colour can carry.
    ///
    /// Not a fixed white, because the accent is a colour picker in Settings and white initials on
    /// a pale yellow are a smear. The threshold is biased towards white rather than set at the
    /// point where the two contrast equally: white on a saturated mid tone is what macOS itself
    /// draws (a Reminders list mark, a Finder tag), and only the genuinely pale colours flip.
    private var contrastingInk: Color {
        guard let accent else { return Palette.textPrimary }
        guard let color = NSColor(Color(hexString: accent)).usingColorSpace(.sRGB) else {
            return .white
        }
        let luminance = 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
        return luminance > 0.35 ? .black : .white
    }

    /// sRGB is gamma encoded, so its components have to be linearised before they mean anything
    /// as a brightness. Averaging the raw bytes instead is what makes a mid blue look as bright
    /// as a mid yellow to the arithmetic and to nothing else.
    private func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
