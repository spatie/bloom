import UIKit
import BloomClient

/// System lists keep long permission explanations readable at every Dynamic Type size.
final class ComposerChoiceController: UITableViewController {
    private let sections: [(String, [ComposerOption])]
    private let selected: String
    private let choose: (String) -> Void

    init(title: String, sections: [(String, [ComposerOption])], selected: String, choose: @escaping (String) -> Void) {
        self.sections = sections; self.selected = selected; self.choose = choose
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("Use init(title:sections:selected:choose:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 58
    }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let option = sections[indexPath.section].1[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = option.label
        content.secondaryText = option.detail
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = option.id == selected ? .checkmark : .none
        if option.id == selected { cell.accessibilityTraits.insert(.selected) }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        choose(sections[indexPath.section].1[indexPath.row].id)
        navigationController?.popViewController(animated: true)
    }
}
