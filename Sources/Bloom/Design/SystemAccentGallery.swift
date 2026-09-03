import SwiftUI
import BloomCore

/// The controls Bloom does not draw, drawn.
///
///     Bloom --snapshot-gallery <dir> --gallery system-accent
///
/// Every other page in this folder photographs something in `Sources/Bloom`. This one photographs
/// AppKit beside Bloom's custom interactive surfaces. Both now resolve through
/// `controlAccentColor`: the bundle accent supplies Bloom's default under Multicolour, and an
/// explicit accent in System Settings wins everywhere. A picture is the only honest check that
/// native controls and custom selections still agree.
///
/// **What this page cannot show, said here rather than left to be wondered about.** All three
/// have the same cause: an accented control, a focus ring and a text selection are all drawn in a
/// neutral grey while their window is not key, and this page is captured with `needsFocus` false
/// because taking the keyboard off whoever is at the machine is not worth a picture. So the ring
/// and the selection are shown as their colours on a plate rather than round a real field and under
/// a real drag, and the on switch is drawn grey, because `.switch` is an `NSSwitch` that reads its
/// window where the tick box, the radio and the slider read the environment this page sets. The
/// four swatches on the right are what those three would be drawn in, which is the same question
/// answered one step indirectly.
///
/// The last row is the segmented control, and it is the one thing on this page that this page
/// cannot answer. It is drawn without the `controlActiveState` override the column beside it gets,
/// so it is photographed in the inactive grey every accented control drops to, exactly as the
/// switch above it is. In a key window it carries `controlAccentColor`. See `InspectorToolbar`,
/// where the same inactive-window behaviour is written down.
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
                        //
                        // It moves the tick box, the radio, the slider and the prominent button,
                        // and it does NOT move the switch, which is the one control this page most
                        // wants to show: `.switch` is an `NSSwitch` under there and it reads its
                        // real window rather than the environment, so the on switch on this page is
                        // grey and is the only thing here that is lying. What it draws when the
                        // window is key is `controlAccentColor`, which is the top swatch on the
                        // right, so the page still answers the question, one step indirectly.
                        .environment(\.controlActiveState, .key)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: Metrics.pane) {
                captioned("What AppKit derives from it") {
                    VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                        swatch(
                            "controlAccentColor",
                            Palette.controlAccent,
                            ink: Palette.selectedEmphasizedText
                        )
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

                captioned("What Bloom draws itself") {
                    VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                        swatch(
                            "Palette.selectedEmphasized",
                            Palette.selectedEmphasized,
                            ink: Palette.selectedEmphasizedText
                        )
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

                captioned("The one this page cannot answer: grey here, accent in a key window") {
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

/// The segmented control, alone. See the head of this file: what it draws here is the inactive
/// grey, not the answer.
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
