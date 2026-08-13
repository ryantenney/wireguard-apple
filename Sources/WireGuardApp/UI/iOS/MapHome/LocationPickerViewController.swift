// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import UIKit

/// Searchable city picker used to assign a location to a tunnel endpoint or
/// to set the user's own location on the Map Home screen.
class LocationPickerViewController: UITableViewController {

    /// Title for the "no specific location" row shown above the city list
    /// (e.g. "Automatic (Time Zone)"), or nil to offer no such row.
    private let clearOptionTitle: String?
    private let onSelect: (MapCity?) -> Void

    private let searchController = UISearchController(searchResultsController: nil)
    private var filteredCities = MapCityDatabase.cities

    private var isSearching: Bool {
        let searchText = searchController.searchBar.text ?? ""
        return !searchText.isEmpty
    }

    private var hasClearSection: Bool {
        return clearOptionTitle != nil && !isSearching
    }

    init(clearOptionTitle: String?, onSelect: @escaping (MapCity?) -> Void) {
        self.clearOptionTitle = clearOptionTitle
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self,
                                                                action: #selector(cancelTapped))
        }
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search cities or countries"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    private func finish(with city: MapCity?) {
        onSelect(city)
        if let navController = navigationController, navController.viewControllers.first !== self {
            navController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        return hasClearSection ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if hasClearSection && section == 0 {
            return 1
        }
        return filteredCities.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "LocationCell")

        if hasClearSection && indexPath.section == 0 {
            cell.textLabel?.text = clearOptionTitle
            cell.detailTextLabel?.text = nil
            cell.imageView?.image = UIImage(systemName: "location.slash")
            return cell
        }

        let city = filteredCities[indexPath.row]
        let flag = city.flagEmoji
        cell.textLabel?.text = flag.isEmpty ? city.name : "\(flag) \(city.name)"
        cell.detailTextLabel?.text = city.country
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = nil
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasClearSection && indexPath.section == 0 {
            finish(with: nil)
        } else {
            finish(with: filteredCities[indexPath.row])
        }
    }
}

// MARK: - UISearchResultsUpdating

extension LocationPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        if query.isEmpty {
            filteredCities = MapCityDatabase.cities
        } else {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            filteredCities = MapCityDatabase.cities.filter {
                $0.name.range(of: query, options: options) != nil
                    || $0.country.range(of: query, options: options) != nil
            }
        }
        tableView.reloadData()
    }
}
