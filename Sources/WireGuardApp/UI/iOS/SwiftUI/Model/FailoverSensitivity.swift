// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// The redesign exposes failover responsiveness as a three-way choice
/// (Patient / Balanced / Fast) rather than three raw interval fields. Each
/// preset maps onto the existing `FailoverSettings` timing values; "Balanced"
/// is the shipping default.
enum FailoverSensitivity: String, CaseIterable, Identifiable {
    case patient
    case balanced
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .patient: return "Patient"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }

    var trafficTimeout: TimeInterval {
        switch self {
        case .patient: return 60
        case .balanced: return 30
        case .fast: return 12
        }
    }

    var healthCheckInterval: TimeInterval {
        switch self {
        case .patient: return 15
        case .balanced: return 10
        case .fast: return 5
        }
    }

    var failbackProbeInterval: TimeInterval {
        switch self {
        case .patient: return 600
        case .balanced: return 300
        case .fast: return 120
        }
    }

    /// Classify existing settings into the nearest preset, keyed off the
    /// traffic timeout (the most user-visible knob).
    init(from settings: FailoverSettings) {
        switch settings.trafficTimeout {
        case ..<20:
            self = .fast
        case 45...:
            self = .patient
        default:
            self = .balanced
        }
    }

    /// Return a copy of `settings` with this preset's timing values applied.
    func applied(to settings: FailoverSettings) -> FailoverSettings {
        var updated = settings
        updated.trafficTimeout = trafficTimeout
        updated.healthCheckInterval = healthCheckInterval
        updated.failbackProbeInterval = failbackProbeInterval
        return updated
    }
}
