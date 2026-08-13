// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Lists every tunnel with its assigned endpoint location (plus the user's
/// own location) and lets each be changed via the city picker. Reached from
/// the Map Home screen's options menu.
class EndpointLocationsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case myLocation = 0
        case tunnels = 1
    }

    private let tunnelsManager: TunnelsManager

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Locations"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(doneTapped))
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .myLocation:
            return 1
        case .tunnels:
            return tunnelsManager.numberOfTunnels()
        case nil:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .myLocation:
            return "My Location"
        case .tunnels:
            return tunnelsManager.numberOfTunnels() > 0 ? "Tunnel Endpoints" : nil
        case nil:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .myLocation:
            return "Used as the starting point of the connection arcs on the map. The automatic setting derives an approximate position from the device time zone; no location permission is used."
        case .tunnels:
            return tunnelsManager.numberOfTunnels() > 0
                ? "Assign each tunnel the city of its WireGuard endpoint to place it on the map."
                : nil
        case nil:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "EndpointLocationCell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "EndpointLocationCell")
        cell.accessoryType = .disclosureIndicator

        switch Section(rawValue: indexPath.section) {
        case .myLocation:
            cell.textLabel?.text = "My Location"
            if let override = EndpointLocationStore.userLocationOverride {
                cell.detailTextLabel?.text = override.flaggedDisplayName
            } else {
                cell.detailTextLabel?.text = "Automatic (Time Zone)"
            }
        case .tunnels:
            let tunnel = tunnelsManager.tunnel(at: indexPath.row)
            cell.textLabel?.text = tunnel.name
            if let location = EndpointLocationStore.location(forTunnelNamed: tunnel.name) {
                cell.detailTextLabel?.text = location.flaggedDisplayName
            } else {
                cell.detailTextLabel?.text = "Not set"
            }
        case nil:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section) {
        case .myLocation:
            let pickerVC = LocationPickerViewController(clearOptionTitle: "Automatic (Time Zone)") { city in
                EndpointLocationStore.userLocationOverride = city.map { EndpointLocation(city: $0) }
            }
            pickerVC.title = "My Location"
            navigationController?.pushViewController(pickerVC, animated: true)
        case .tunnels:
            let tunnel = tunnelsManager.tunnel(at: indexPath.row)
            let tunnelName = tunnel.name
            let pickerVC = LocationPickerViewController(clearOptionTitle: "No Location") { city in
                EndpointLocationStore.setLocation(city.map { EndpointLocation(city: $0) }, forTunnelNamed: tunnelName)
            }
            pickerVC.title = tunnelName
            navigationController?.pushViewController(pickerVC, animated: true)
        case nil:
            break
        }
    }
}
