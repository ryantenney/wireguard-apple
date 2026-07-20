// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// A simple single-choice checkmark list used for picking the speed test
/// direction and duration.
class SpeedTestPickerViewController: UITableViewController {

    private let options: [String]
    private var selectedIndex: Int

    var onSelect: ((Int) -> Void)?

    init(title: String, options: [String], selectedIndex: Int) {
        self.options = options
        self.selectedIndex = selectedIndex
        super.init(style: .grouped)
        self.title = title
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(CheckmarkCell.self)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: CheckmarkCell = tableView.dequeueReusableCell(for: indexPath)
        cell.message = options[indexPath.row]
        cell.isChecked = indexPath.row == selectedIndex
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedIndex = indexPath.row
        tableView.reloadData()
        onSelect?(indexPath.row)
        navigationController?.popViewController(animated: true)
    }
}
