// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import XCTest

class SettingsCodableTests: XCTestCase {

    // MARK: - FailoverSettings

    func testFailoverSettingsDefaults() throws {
        let decoded = try JSONDecoder().decode(FailoverSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.trafficTimeout, 30)
        XCTAssertEqual(decoded.healthCheckInterval, 10)
        XCTAssertEqual(decoded.failbackProbeInterval, 300)
        XCTAssertTrue(decoded.autoFailback)
        XCTAssertTrue(decoded.useBackgroundProbes)
        XCTAssertFalse(decoded.hotSpare)
        XCTAssertNil(decoded.persistentKeepaliveOverride)
    }

    func testFailoverSettingsLegacyHandshakeTimeoutMigration() throws {
        // Legacy payloads carried handshakeTimeout (e.g. 180s); decoding must
        // fall back to the modern trafficTimeout default, not the stale value.
        let legacy = Data(#"{"handshakeTimeout": 180}"#.utf8)
        let decoded = try JSONDecoder().decode(FailoverSettings.self, from: legacy)
        XCTAssertEqual(decoded.trafficTimeout, 30)
    }

    func testFailoverSettingsRoundTrip() throws {
        var settings = FailoverSettings()
        settings.trafficTimeout = 45
        settings.hotSpare = true
        settings.persistentKeepaliveOverride = 15
        let decoded = try JSONDecoder().decode(FailoverSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - WarmSpareSettings

    func testWarmSpareSettingsDefaults() throws {
        let decoded = try JSONDecoder().decode(WarmSpareSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertTrue(decoded.adaptiveWarming)
        XCTAssertEqual(decoded.warmKeepaliveInterval, 25)
        XCTAssertEqual(decoded.probePort, 51821)
        XCTAssertEqual(decoded.switchRttMs, 300)
        XCTAssertEqual(decoded.switchLossPct, 20)
        XCTAssertEqual(decoded.dwellSeconds, 10)
    }

    func testWarmSpareSettingsRoundTrip() throws {
        var settings = WarmSpareSettings()
        settings.enabled = true
        settings.adaptiveWarming = false
        settings.probePort = 40000
        settings.switchRttMs = 500
        let decoded = try JSONDecoder().decode(WarmSpareSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testWarmSpareSettingsPartialPayloadKeepsDefaults() throws {
        let partial = Data(#"{"enabled": true, "probePort": 12345}"#.utf8)
        let decoded = try JSONDecoder().decode(WarmSpareSettings.self, from: partial)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.probePort, 12345)
        XCTAssertTrue(decoded.adaptiveWarming)
        XCTAssertEqual(decoded.dwellSeconds, 10)
    }
}
