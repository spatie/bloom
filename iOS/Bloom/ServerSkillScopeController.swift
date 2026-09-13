import UIKit
import BloomClient

/// Project files stay read-only. Selecting a workspace adds its skills to the server inventory.
final class ServerSkillScopeController: UITableViewController {
    private let workspaces: [RemoteWorkspace]
    private let selected: WorkspaceID?
    private let onSelect: (WorkspaceID?) -> Void

    init(workspaces: [RemoteWorkspace], selected: WorkspaceID?, onSelect: @escaping (WorkspaceID?) -> Void) {
        self.workspaces = workspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.selected = selected; self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(workspaces:selected:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Project Skills"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView); tableView.cellLayoutMarginsFollowReadableWidth = true
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : workspaces.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 1 ? "Choose a workspace" : nil }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "Project skills are shown alongside server skills. To change a project skill, edit its files in the workspace." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let workspace = indexPath.section == 1 ? workspaces[indexPath.row] : nil
        let cell = BloomTheme.cell(title: workspace?.name ?? "Server Skills Only", detail: workspace?.branch,
            symbol: workspace == nil ? "server.rack" : "square.stack.3d.up", disclosure: false)
        cell.accessoryType = workspace?.id == selected ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(indexPath.section == 1 ? workspaces[indexPath.row].id : nil)
        navigationController?.popViewController(animated: true)
    }
}
