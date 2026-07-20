// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Manages the saved speed test server list: tap to select, edit mode to
/// modify or delete, + to add, and a button to restore the built-in public
/// iperf3 servers.
class SpeedTestServerListViewController: UITableViewController {

    private var servers = [SpeedTestServer]()
    private var selectedServerId: UUID?

    var onSelectionChanged: ((SpeedTestServer) -> Void)?

    init(selectedServerId: UUID?) {
        self.selectedServerId = selectedServerId
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = tr("speedTestServersViewTitle")

        let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        navigationItem.rightBarButtonItems = [addButton, editButtonItem]

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SpeedTestServerCell.self)
        tableView.register(ButtonCell.self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        servers = SpeedTestServerStore.loadServers()
        tableView.reloadData()
    }

    @objc private func addTapped() {
        let editVC = SpeedTestServerEditViewController(server: nil)
        editVC.onSave = { [weak self] server in
            SpeedTestServerStore.add(server)
            self?.reload()
        }
        navigationController?.pushViewController(editVC, animated: true)
    }

    private func editServer(at index: Int) {
        let editVC = SpeedTestServerEditViewController(server: servers[index])
        editVC.onSave = { [weak self] server in
            SpeedTestServerStore.update(server)
            self?.reload()
            if server.id == self?.selectedServerId {
                self?.onSelectionChanged?(server)
            }
        }
        navigationController?.pushViewController(editVC, animated: true)
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? servers.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return servers.isEmpty ? tr("speedTestServersEmptyFooter") : tr("speedTestServersSelectFooter")
        case 1:
            return tr("speedTestServersPublicFooter")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell: ButtonCell = tableView.dequeueReusableCell(for: indexPath)
            cell.buttonText = tr("speedTestRestoreBuiltInServers")
            cell.onTapped = { [weak self] in
                SpeedTestServerStore.restoreBuiltInServers()
                self?.reload()
            }
            return cell
        }
        let cell: SpeedTestServerCell = tableView.dequeueReusableCell(for: indexPath)
        let server = servers[indexPath.row]
        cell.name = server.name
        cell.detail = "\(server.kind.localizedName) · \(server.endpointDescription)"
        cell.isChecked = server.id == selectedServerId
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        if tableView.isEditing {
            editServer(at: indexPath.row)
        } else {
            let server = servers[indexPath.row]
            selectedServerId = server.id
            onSelectionChanged?(server)
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.section == 0 else { return }
        let server = servers[indexPath.row]
        SpeedTestServerStore.remove(withId: server.id)
        servers.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
