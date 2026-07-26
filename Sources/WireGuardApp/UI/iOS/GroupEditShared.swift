// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

// Fragments shared verbatim between the two group edit screens (failover,
// TiT). A common base class is deliberately not introduced yet — see the
// Tier 3 notes in the refactor plan.
extension UITableViewController {

    /// The on-demand section's rows: two interface switches plus the SSID
    /// chevron that appears while the Wi-Fi switch is on.
    func groupOnDemandCell(for tableView: UITableView, at indexPath: IndexPath,
                           fields: [ActivateOnDemandViewModel.OnDemandField],
                           viewModel: ActivateOnDemandViewModel,
                           onDemandSection: Int) -> UITableViewCell {
        let field = fields[indexPath.row]
        if indexPath.row < 2 {
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.isOn = viewModel.isEnabled(field: field)
            cell.onSwitchToggled = { isOn in
                viewModel.setEnabled(field: field, isEnabled: isOn)
                let ssidIndexPath = IndexPath(row: 2, section: onDemandSection)
                if field == .wiFiInterface {
                    if isOn {
                        tableView.insertRows(at: [ssidIndexPath], with: .fade)
                    } else {
                        tableView.deleteRows(at: [ssidIndexPath], with: .fade)
                    }
                }
            }
            return cell
        } else {
            let cell: ChevronCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = field.localizedUIString
            cell.detailMessage = viewModel.localizedSSIDDescription
            return cell
        }
    }

    /// The delete confirmation alert; the caller supplies the kind-specific
    /// title and the removal action.
    func confirmGroupDelete(groupName: String, title: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(
            title: title,
            message: "Are you sure you want to delete '\(groupName)'? This won't delete the individual tunnels.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            onConfirm()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
