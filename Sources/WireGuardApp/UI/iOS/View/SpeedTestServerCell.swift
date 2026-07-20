// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Subtitle-style cell for a speed test server row: name on top, protocol
/// kind and endpoint underneath, checkmark accessory when selected.
class SpeedTestServerCell: UITableViewCell {

    var name: String {
        get { return textLabel?.text ?? "" }
        set(value) { textLabel?.text = value }
    }

    var detail: String {
        get { return detailTextLabel?.text ?? "" }
        set(value) { detailTextLabel?.text = value }
    }

    var isChecked = false {
        didSet {
            accessoryType = isChecked ? .checkmark : .none
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        detailTextLabel?.textColor = .secondaryLabel
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        name = ""
        detail = ""
        isChecked = false
    }
}
