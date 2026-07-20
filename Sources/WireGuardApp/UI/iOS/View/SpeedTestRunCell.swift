// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// The live speed test readout: big download/upload throughput numbers, a
/// progress bar for the elapsed portion of the run, and a status line.
class SpeedTestRunCell: UITableViewCell {

    private let downloadValueLabel = SpeedTestRunCell.makeValueLabel()
    private let uploadValueLabel = SpeedTestRunCell.makeValueLabel()
    private let downloadCaptionLabel = SpeedTestRunCell.makeCaptionLabel()
    private let uploadCaptionLabel = SpeedTestRunCell.makeCaptionLabel()

    private let progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.progress = 0
        return progressView
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private static func makeValueLabel() -> UILabel {
        let label = UILabel()
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.text = "—"
        return label
    }

    private static func makeCaptionLabel() -> UILabel {
        let label = UILabel()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        downloadCaptionLabel.text = "↓ " + tr("speedTestDownloadLabel")
        uploadCaptionLabel.text = "↑ " + tr("speedTestUploadLabel")

        let downloadStack = UIStackView(arrangedSubviews: [downloadValueLabel, downloadCaptionLabel])
        downloadStack.axis = .vertical
        downloadStack.spacing = 2

        let uploadStack = UIStackView(arrangedSubviews: [uploadValueLabel, uploadCaptionLabel])
        uploadStack.axis = .vertical
        uploadStack.spacing = 2

        let valuesStack = UIStackView(arrangedSubviews: [downloadStack, uploadStack])
        valuesStack.axis = .horizontal
        valuesStack.distribution = .fillEqually
        valuesStack.spacing = 16

        let mainStack = UIStackView(arrangedSubviews: [valuesStack, progressView, statusLabel])
        mainStack.axis = .vertical
        mainStack.spacing = 12

        contentView.addSubview(mainStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            contentView.layoutMarginsGuide.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 8),
            contentView.layoutMarginsGuide.bottomAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 8)
        ])
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(downloadText: String, uploadText: String, statusText: String, progress: Float?) {
        downloadValueLabel.text = downloadText
        uploadValueLabel.text = uploadText
        statusLabel.text = statusText
        if let progress = progress {
            progressView.isHidden = false
            progressView.progress = progress
        } else {
            progressView.isHidden = true
            progressView.progress = 0
        }
    }
}
