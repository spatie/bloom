import UIKit
import BloomClient

/// The Mac and mobile clients share the measured colour ramp. UIKit supplies semantic ink,
/// scalable type and native controls, so Bloom's identity does not cost platform behaviour.
@MainActor
enum BloomTheme {
    static let background = colour(PaletteInk.surface)
    static let panel = colour(PaletteInk.surfaceSunken)
    static let raised = colour(PaletteInk.surfaceRaised)
    static let border = colour(PaletteInk.border)
    static let accent = colour(PaletteInk.accentFill)
    static let secondary = colour(PaletteInk.textTertiary)

    static func colour(_ pair: PaletteInk.Pair) -> UIColor {
        UIColor { traits in
            let hex = pair.member(dark: traits.userInterfaceStyle == .dark)
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    static func label(_ text: String, style: UIFont.TextStyle = .body, secondary: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = secondary ? Self.secondary : .label
        label.numberOfLines = 0
        return label
    }

    static func navigation(_ root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.view.tintColor = accent
        navigation.navigationBar.tintColor = accent
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = background
        appearance.shadowColor = .clear
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        return navigation
    }

    static func list(_ table: UITableView) {
        table.backgroundColor = panel
        table.separatorColor = border
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        table.sectionHeaderTopPadding = 12
    }

    static func cell(title: String, detail: String? = nil, symbol: String,
                     tint: UIColor = accent, disclosure: Bool = true) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.secondaryText = detail
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = secondary
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        content.imageProperties.tintColor = tint
        content.imageToTextPadding = 10
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        cell.contentConfiguration = content
        cell.backgroundColor = background
        cell.accessoryType = disclosure ? .disclosureIndicator : .none
        return cell
    }
}
