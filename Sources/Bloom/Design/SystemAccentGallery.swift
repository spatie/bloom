import SwiftUI
import BloomCore

/// The controls Bloom does not draw, drawn.
///
///     Bloom --snapshot-gallery <dir> --gallery system-accent
///
/// Every other page in this folder photographs something in `Sources/Bloom`. This one photographs
/// AppKit, on purpose, because the thing under review is a colour the app hands over and never
/// touches again. `Palette.accent` overrode `controlAccentColor` for everything Bloom drew itself,
/// and a `.tint` reaches none of these: a switch, a tick box, a radio dot, a slider's track, a
/// stepper, a focus ring and the ground under selected text are all drawn by the system off the
/// accent it resolves for the process. So the window held Bloom's blue and the user's at once, and
/// no test in this repository could see it, because the pixels are AppKit's.
///
/// `NSAccentColorName` in `Resources/Info.plist` is what changed that, and the only honest way to
/// review it is a picture: the ratio tests can hold a floor over the two colours AppKit DERIVES
/// (see `PaletteInk.accentTextSelection`) and can say nothing at all about whether a switch came
/// out teal.
///
/// **Two things this page cannot show, said here rather than left to be wondered about.** The focus
/// ring is drawn round the first responder in a key window, and this page is captured with
/// `needsFocus` false because taking the keyboard off whoever is at the machine is not worth a
/// picture, so the ring is shown as its colour on a plate rather than round a real field. And the
/// selection is `selectedTextBackgroundColor` with the ink AppKit really puts on it, painted rather
/// than dragged over, for the same reason: an unfocused text view draws the unemphasised grey
/// instead and the page would be photographing the wrong colour.
///
/// The last row is the control that deliberately does not follow, and it is here so the next person
/// does not read its absence as a bug. See `InspectorToolbar` and `SettingsView`: a segmented
/// control's selected cell is a neutral capsule on this SDK, and it stays one.
struct SystemAccentGallery: View {
    var app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.pane) {
            VStack(alignment: .leading, spacing: Metrics.pane) {
                captioned("What AppKit draws off the accent, and no .tint can reach") {
                    SystemAccentControls()
                        // Every accented control drops to a neutral grey when its window is not
                        // key, which is exactly what this page is captured in: `needsFocus` is
                        // false, so the window is ordered front without the app being activated
                        // and the first capture came back with an "on" switch identical to the
                        // "off" one. `controlActiveState` is the environment value SwiftUI's own
                        // controls read to decide that, so the page states the answer rather than
                        // taking the keys off whoever is at the machine to earn it. The window is
                        // still inactive; only these controls are told to draw as though it were
                        // not.
                        .environment(\.controlActiveState, .key)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: Metrics.pane) {
                captioned("What AppKit derives from it") {
                    VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                        swatch("controlAccentColor", Color(nsColor: .controlAccentColor), ink: .white)
                        swatch(
                            "keyboardFocusIndicatorColor",
                            Palette.focusRing,
                            ink: Color(nsColor: .labelColor)
                        )
                        swatch(
                            "selectedTextBackgroundColor",
                            Palette.textSelection,
                            ink: Color(nsColor: .selectedTextColor)
                        )
                        swatch(
                            "selectedContentBackgroundColor",
                            Color(nsColor: .selectedContentBackgroundColor),
                            ink: Color(nsColor: .alternateSelectedControlTextColor)
                        )
                    }
                }

                captioned("What Bloom draws itself, for comparison") {
                    VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                        swatch("Palette.accentFill", Palette.accentFill, ink: Palette.textInverted)
                        swatch("Palette.selected", Palette.selected, ink: Palette.textPrimary)
                        HStack(spacing: Metrics.spacingWide) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Palette.accent)
                            Text("Palette.accent, the ink half of the ramp")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }

                captioned("The one that stays neutral, and is meant to") {
                    SystemAccentSegments()
                }

                Spacer(minLength: 0)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
        .environment(app)
    }

    /// A band of the colour with the ink AppKit really puts on it, so the page answers "can this be
    /// read" rather than only "what hue is it". The name is drawn on the band for the same reason.
    private func swatch(_ name: String, _ fill: Color, ink: Color) -> some View {
        Text(name)
            .font(Typo.caption)
            .foregroundStyle(ink)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacingWide)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: .rect(cornerRadius: Metrics.cornerSmall))
    }

    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

/// The controls themselves, in their own type because each needs somewhere for its binding to
/// point and a `body` full of `@State` reads worse than a harness does.
///
/// Both states of everything that has two, because "on" is the only state that carries the accent
/// and an off switch beside it is what says the on one is coloured rather than simply dark.
private struct SystemAccentControls: View {
    @State private var switchOn = true
    @State private var switchOff = false
    @State private var boxOn = true
    @State private var boxOff = false
    @State private var choice = 1
    @State private var slider = 0.65
    @State private var steps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Toggle("A switch, on", isOn: $switchOn)
                .toggleStyle(.switch)
            Toggle("A switch, off", isOn: $switchOff)
                .toggleStyle(.switch)

            Toggle("A tick box, ticked", isOn: $boxOn)
                .toggleStyle(.checkbox)
            Toggle("A tick box, clear", isOn: $boxOff)
                .toggleStyle(.checkbox)

            Picker("", selection: $choice) {
                Text("A radio, unchosen").tag(0)
                Text("A radio, chosen").tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Slider(value: $slider)

            ProgressView(value: slider)

            Stepper("A stepper at \(steps)", value: $steps, in: 0...9)

            HStack(spacing: Metrics.spacingWide) {
                Button("Prominent") {}
                    .buttonStyle(.borderedProminent)
                Button("Bordered") {}
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// The segmented control, alone, because the answer about it is "unchanged" and that is worth
/// photographing next to everything that did change.
private struct SystemAccentSegments: View {
    @State private var segment = 0

    var body: some View {
        Picker("", selection: $segment) {
            Text("Diff").tag(0)
            Text("Files").tag(1)
            Text("Checks").tag(2)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// `needsFocus` is false, and the focus ring is the price. Taking the keys off the person at
    /// the machine to photograph a two point outline is the wrong trade, so the ring is on this
    /// page as its colour rather than round a field, and the head of `SystemAccentGallery` says so.
    static let systemAccent = Gallery(
        name: "system-accent",
        title: "System accent",
        size: CGSize(width: 820, height: 620),
        needsFocus: false,
        view: { app in AnyView(SystemAccentGallery(app: app)) }
    )
}
