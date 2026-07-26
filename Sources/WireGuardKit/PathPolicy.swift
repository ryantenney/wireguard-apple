// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import Foundation

/// A path-quality sample set as reported by the Go bridge's warm spare
/// controller (median RTT, loss percentage, sample count).
public struct PathQuality {
    public let rttMs: Double
    public let lossPct: Int
    public let samples: Int

    public init(rttMs: Double, lossPct: Int, samples: Int) {
        self.rttMs = rttMs
        self.lossPct = lossPct
        self.samples = samples
    }

    /// Parse from the Go bridge's state JSON (`primaryPath` / `cellularPath`
    /// objects in `wgWarmGetState`).
    public init?(dict: [String: Any]?) {
        guard let dict = dict else { return nil }
        self.rttMs = (dict["rttMs"] as? NSNumber)?.doubleValue ?? -1
        self.lossPct = (dict["lossPct"] as? NSNumber)?.intValue ?? -1
        self.samples = (dict["samples"] as? NSNumber)?.intValue ?? 0
    }
}

/// The pure decision predicates of warm spare path control, extracted from
/// the path controller so they are unit-testable without NWPathMonitor or
/// timer plumbing.
public struct PathPolicy {
    /// Hard thresholds: flip to cellular when breached.
    public let switchRttMs: Int
    public let switchLossPct: Int

    /// Minimum probe samples before quality-based decisions.
    public let minSamples: Int

    public init(settings: WarmSpareSettings, minSamples: Int = 3) {
        self.switchRttMs = settings.switchRttMs
        self.switchLossPct = settings.switchLossPct
        self.minSamples = minSamples
    }

    /// Hard thresholds: the default path has failed badly enough to flip.
    public func isBreaching(_ quality: PathQuality) -> Bool {
        guard quality.samples >= minSamples else { return false }
        if quality.rttMs >= 0 && quality.rttMs >= Double(switchRttMs) { return true }
        if quality.lossPct >= 0 && quality.lossPct >= switchLossPct { return true }
        // All probes lost is the strongest breach signal of all.
        if quality.rttMs < 0 && quality.lossPct >= 100 { return true }
        return false
    }

    /// Soft thresholds (two-thirds RTT, half loss): quality is trending
    /// toward the switch thresholds — time to warm the spare.
    public func isDegrading(_ quality: PathQuality) -> Bool {
        guard quality.samples >= minSamples else { return false }
        if quality.rttMs >= 0 && quality.rttMs >= Double(switchRttMs) * 2 / 3 { return true }
        if quality.lossPct >= 0 && quality.lossPct >= switchLossPct / 2 { return true }
        return false
    }
}
