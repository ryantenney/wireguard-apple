// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// Resolves the user's approximate location for the Map Home landing page
/// without requesting any system location permission: a manually chosen
/// location if one is set, otherwise the device time zone's representative
/// coordinates from the tz database.
enum UserLocationProvider {

    struct ApproximateLocation {
        let latitude: Double
        let longitude: Double
        let label: String
        let isManualOverride: Bool
    }

    static func current() -> ApproximateLocation {
        if let override = EndpointLocationStore.userLocationOverride {
            return ApproximateLocation(latitude: override.latitude,
                                       longitude: override.longitude,
                                       label: override.displayName,
                                       isManualOverride: true)
        }
        let timeZone = TimeZone.current
        let coordinates = TimeZoneLocationTable.coordinates(for: timeZone)
        return ApproximateLocation(latitude: coordinates.latitude,
                                   longitude: coordinates.longitude,
                                   label: timeZoneCityName(from: timeZone.identifier),
                                   isManualOverride: false)
    }

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires"
    private static func timeZoneCityName(from identifier: String) -> String {
        guard let cityComponent = identifier.split(separator: "/").last else { return identifier }
        return cityComponent.replacingOccurrences(of: "_", with: " ")
    }
}
