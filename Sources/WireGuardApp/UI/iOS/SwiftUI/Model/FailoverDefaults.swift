// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// App-level defaults for newly created failover groups, surfaced in the
/// redesigned Settings screen ("Failover defaults"). These are advisory: they
/// seed new groups; existing groups keep their own stored `FailoverSettings`.
enum FailoverDefaults {
    private static let backgroundProbesKey = "wgnext.failover.defaultBackgroundProbes"
    private static let sensitivityKey = "wgnext.failover.defaultSensitivity"

    static var useBackgroundProbes: Bool {
        get {
            if UserDefaults.standard.object(forKey: backgroundProbesKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: backgroundProbesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: backgroundProbesKey) }
    }

    static var sensitivity: FailoverSensitivity {
        get {
            FailoverSensitivity(rawValue: UserDefaults.standard.string(forKey: sensitivityKey) ?? "") ?? .balanced
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sensitivityKey) }
    }
}
