// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Manages the saved speed test server list: tap to select, edit mode to
/// modify or delete, and + to add. There are no built-in servers — the user
/// adds their own iperf3 or OpenSpeedTest server.
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
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return servers.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return servers.isEmpty ? tr("speedTestServersEmptyFooter") : tr("speedTestServersSelectFooter")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
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
