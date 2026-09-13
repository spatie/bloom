import UIKit
import SwiftTerm
import BloomClient

@MainActor
enum MobileTerminalAppearance {
    static func apply(to terminal: TerminalView, traits: UITraitCollection) {
        let colours = TerminalPalette.ansi(resolve: BloomTheme.colour, purple: UIColor.systemPurple, cyan: UIColor.systemTeal)
        terminal.installColors(colours.map { colour in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            colour.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return SwiftTerm.Color(red8: UInt16(clamping: Int((red * 255).rounded())),
                                   green8: UInt16(clamping: Int((green * 255).rounded())),
                                   blue8: UInt16(clamping: Int((blue * 255).rounded())))
        })
        terminal.nativeForegroundColor = UIColor.label.resolvedColor(with: traits).withAlphaComponent(1)
        terminal.nativeBackgroundColor = BloomTheme.panel.resolvedColor(with: traits)
        terminal.caretColor = BloomTheme.accent.resolvedColor(with: traits)
        terminal.caretTextColor = BloomTheme.panel.resolvedColor(with: traits)
        terminal.selectionHandleColor = BloomTheme.accent.resolvedColor(with: traits)
        terminal.selectedTextBackgroundColor = BloomTheme.colour(PaletteInk.selected).resolvedColor(with: traits)
        terminal.selectedTextForegroundColor = UIColor.label.resolvedColor(with: traits).withAlphaComponent(1)
    }
}
