// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// A geographic location assigned to a tunnel's endpoint (or chosen by the
/// user as their own location) for display on the Map Home landing page.
struct EndpointLocation: Codable, Equatable {
    var city: String
    var country: String
    var countryCode: String
    var latitude: Double
    var longitude: Double

    init(city: MapCity) {
        self.city = city.name
        self.country = city.country
        self.countryCode = city.countryCode
        self.latitude = city.latitude
        self.longitude = city.longitude
    }

    var displayName: String {
        return city.isEmpty ? country : city
    }

    var flagEmoji: String {
        return CountryFlag.emoji(forCountryCode: countryCode)
    }

    /// "🇩🇪 Frankfurt", or just "Frankfurt" when no flag is available.
    var flaggedDisplayName: String {
        let flag = flagEmoji
        return flag.isEmpty ? displayName : "\(flag) \(displayName)"
    }
}

enum CountryFlag {
    /// Flag emoji for an ISO 3166-1 alpha-2 country code, or an empty string
    /// when the code contains anything other than A-Z letters.
    static func emoji(forCountryCode code: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in code.uppercased().unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            guard let regionalIndicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) else { continue }
            scalars.append(regionalIndicator)
        }
        return String(scalars)
    }
}

extension MapCity {
    var flagEmoji: String {
        return CountryFlag.emoji(forCountryCode: countryCode)
    }
}

/// Persists tunnel name → endpoint location assignments, plus the user's
/// manual location override, in the shared app group defaults. Follows the
/// same pattern as RecentTunnelsTracker.
class EndpointLocationStore {

    static let locationsDidChangeNotification = Notification.Name("MapHomeEndpointLocationsDidChange")

    private static let keyTunnelLocations = "mapHomeTunnelEndpointLocations"
    private static let keyUserLocation = "mapHomeUserLocationOverride"

    private static var userDefaults: UserDefaults? {
        guard let appGroupId = FileManager.appGroupId else {
            wg_log(.error, staticMessage: "Cannot obtain app group ID from bundle for endpoint locations")
            return nil
        }
        return UserDefaults(suiteName: appGroupId)
    }

    static func locationsByTunnelName() -> [String: EndpointLocation] {
        guard let data = userDefaults?.data(forKey: keyTunnelLocations) else { return [:] }
        return (try? JSONDecoder().decode([String: EndpointLocation].self, from: data)) ?? [:]
    }

    static func location(forTunnelNamed tunnelName: String) -> EndpointLocation? {
        return locationsByTunnelName()[tunnelName]
    }

    static func setLocation(_ location: EndpointLocation?, forTunnelNamed tunnelName: String) {
        var locations = locationsByTunnelName()
        locations[tunnelName] = location
        save(locations)
    }

    /// The user's manually chosen "my location", or nil to approximate from
    /// the device time zone.
    static var userLocationOverride: EndpointLocation? {
        get {
            guard let data = userDefaults?.data(forKey: keyUserLocation) else { return nil }
            return try? JSONDecoder().decode(EndpointLocation.self, from: data)
        }
        set {
            if let newValue = newValue, let data = try? JSONEncoder().encode(newValue) {
                userDefaults?.set(data, forKey: keyUserLocation)
            } else {
                userDefaults?.removeObject(forKey: keyUserLocation)
            }
            notifyChanged()
        }
    }

    static func handleTunnelRenamed(oldName: String, newName: String) {
        var locations = locationsByTunnelName()
        guard let moved = locations.removeValue(forKey: oldName) else { return }
        locations[newName] = moved
        save(locations)
    }

    static func handleTunnelRemoved(tunnelName: String) {
        var locations = locationsByTunnelName()
        guard locations.removeValue(forKey: tunnelName) != nil else { return }
        save(locations)
    }

    static func cleanupTunnels(except tunnelNamesToKeep: Set<String>) {
        let locations = locationsByTunnelName()
        let kept = locations.filter { tunnelNamesToKeep.contains($0.key) }
        if kept.count != locations.count {
            save(kept)
        }
    }

    private static func save(_ locations: [String: EndpointLocation]) {
        if let data = try? JSONEncoder().encode(locations) {
            userDefaults?.set(data, forKey: keyTunnelLocations)
        }
        notifyChanged()
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: locationsDidChangeNotification, object: nil)
    }
}
