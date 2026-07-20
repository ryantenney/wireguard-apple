// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Add/edit form for a speed test server. The HTTP options section (TLS,
/// download/upload paths) is only shown for OpenSpeedTest-style servers.
class SpeedTestServerEditViewController: UITableViewController {

    private enum Field {
        case name
        case kindIperf3
        case kindOpenSpeedTest
        case host
        case port
        case useTLS
        case downloadPath
        case uploadPath
    }

    private var server: SpeedTestServer
    private var portText: String
    private let isNewServer: Bool

    var onSave: ((SpeedTestServer) -> Void)?

    init(server: SpeedTestServer?) {
        if let server = server {
            self.server = server
            isNewServer = false
        } else {
            self.server = SpeedTestServer(name: "", kind: .iperf3, host: "")
            isNewServer = true
        }
        portText = String(self.server.port)
        super.init(style: .grouped)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var fieldsBySection: [[Field]] {
        var sections: [[Field]] = [
            [.name],
            [.kindIperf3, .kindOpenSpeedTest],
            [.host, .port]
        ]
        if server.kind == .openSpeedTest {
            sections.append([.useTLS, .downloadPath, .uploadPath])
        }
        return sections
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNewServer ? tr("speedTestAddServerViewTitle") : tr("speedTestEditServerViewTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(EditableTextCell.self)
        tableView.register(CheckmarkCell.self)
        tableView.register(SwitchCell.self)
    }

    @objc private func saveTapped() {
        view.endEditing(true)

        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            showValidationAlert(tr("speedTestAlertNameEmpty"))
            return
        }
        guard !host.isEmpty, !host.contains(" ") else {
            showValidationAlert(tr("speedTestAlertHostInvalid"))
            return
        }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else {
            showValidationAlert(tr("speedTestAlertPortInvalid"))
            return
        }

        server.name = name
        server.host = host
        server.port = port
        server.downloadPath = server.downloadPath.trimmingCharacters(in: .whitespaces)
        server.uploadPath = server.uploadPath.trimmingCharacters(in: .whitespaces)
        // A user-modified copy of a built-in server is theirs now.
        server.isBuiltIn = false

        onSave?(server)
        navigationController?.popViewController(animated: true)
    }

    private func showValidationAlert(_ message: String) {
        let alert = UIAlertController(title: tr("speedTestAlertInvalidServerTitle"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: tr("actionOK"), style: .default))
        present(alert, animated: true)
    }

    private func setKind(_ kind: SpeedTestServerKind) {
        guard server.kind != kind else { return }
        let defaultPort: UInt16 = server.kind == .iperf3 ? 5201 : 3000
        server.kind = kind
        // Swap in the new kind's default port if the user hasn't customized it.
        if portText == String(defaultPort) {
            let newDefault: UInt16 = kind == .iperf3 ? 5201 : 3000
            portText = String(newDefault)
            server.port = newDefault
        }
        tableView.reloadData()
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return fieldsBySection.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return fieldsBySection[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return tr("speedTestEditSectionName")
        case 1:
            return tr("speedTestEditSectionKind")
        case 2:
            return tr("speedTestEditSectionEndpoint")
        case 3:
            return tr("speedTestEditSectionHTTPOptions")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fieldsBySection[indexPath.section][indexPath.row]
        switch field {
        case .name:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.placeholder = tr("speedTestEditPlaceholderName")
            cell.message = server.name
            cell.valueTextField.keyboardType = .default
            cell.onValueBeingEdited = { [weak self] value in
                self?.server.name = value
            }
            return cell
        case .kindIperf3:
            let cell: CheckmarkCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = SpeedTestServerKind.iperf3.localizedName
            cell.isChecked = server.kind == .iperf3
            return cell
        case .kindOpenSpeedTest:
            let cell: CheckmarkCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = SpeedTestServerKind.openSpeedTest.localizedName
            cell.isChecked = server.kind == .openSpeedTest
            return cell
        case .host:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.placeholder = tr("speedTestEditPlaceholderHost")
            cell.message = server.host
            cell.valueTextField.keyboardType = .URL
            cell.onValueBeingEdited = { [weak self] value in
                self?.server.host = value
            }
            return cell
        case .port:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.placeholder = tr("speedTestEditPlaceholderPort")
            cell.message = portText
            cell.valueTextField.keyboardType = .numberPad
            cell.onValueBeingEdited = { [weak self] value in
                self?.portText = value
            }
            return cell
        case .useTLS:
            let cell: SwitchCell = tableView.dequeueReusableCell(for: indexPath)
            cell.message = tr("speedTestEditFieldUseTLS")
            cell.isOn = server.useTLS
            cell.onSwitchToggled = { [weak self] isOn in
                self?.server.useTLS = isOn
            }
            return cell
        case .downloadPath:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.placeholder = tr("speedTestEditPlaceholderDownloadPath")
            cell.message = server.downloadPath
            cell.valueTextField.keyboardType = .URL
            cell.onValueBeingEdited = { [weak self] value in
                self?.server.downloadPath = value
            }
            return cell
        case .uploadPath:
            let cell: EditableTextCell = tableView.dequeueReusableCell(for: indexPath)
            cell.placeholder = tr("speedTestEditPlaceholderUploadPath")
            cell.message = server.uploadPath
            cell.valueTextField.keyboardType = .URL
            cell.onValueBeingEdited = { [weak self] value in
                self?.server.uploadPath = value
            }
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let field = fieldsBySection[indexPath.section][indexPath.row]
        switch field {
        case .kindIperf3:
            setKind(.iperf3)
        case .kindOpenSpeedTest:
            setKind(.openSpeedTest)
        default:
            break
        }
    }
}
