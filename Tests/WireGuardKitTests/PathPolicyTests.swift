// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import XCTest

class PathPolicyTests: XCTestCase {

    private var policy: PathPolicy {
        // Defaults: switch at 300 ms RTT or 20% loss, min 3 samples.
        return PathPolicy(settings: WarmSpareSettings())
    }

    // MARK: - Breach (hard flip)

    func testHealthyPathNeitherBreachesNorDegrades() {
        let q = PathQuality(rttMs: 40, lossPct: 0, samples: 10)
        XCTAssertFalse(policy.isBreaching(q))
        XCTAssertFalse(policy.isDegrading(q))
    }

    func testRttBreach() {
        XCTAssertTrue(policy.isBreaching(PathQuality(rttMs: 300, lossPct: 0, samples: 5)))
        XCTAssertFalse(policy.isBreaching(PathQuality(rttMs: 299, lossPct: 0, samples: 5)))
    }

    func testLossBreach() {
        XCTAssertTrue(policy.isBreaching(PathQuality(rttMs: 40, lossPct: 20, samples: 5)))
        XCTAssertFalse(policy.isBreaching(PathQuality(rttMs: 40, lossPct: 19, samples: 5)))
    }

    func testAllProbesLostIsABreach() {
        // No successful samples: rttMs is the -1 sentinel, loss 100%.
        XCTAssertTrue(policy.isBreaching(PathQuality(rttMs: -1, lossPct: 100, samples: 5)))
    }

    func testTooFewSamplesNeverBreaches() {
        XCTAssertFalse(policy.isBreaching(PathQuality(rttMs: 5000, lossPct: 100, samples: 2)))
        XCTAssertFalse(policy.isDegrading(PathQuality(rttMs: 5000, lossPct: 100, samples: 2)))
    }

    // MARK: - Degradation (adaptive warming trigger)

    func testRttDegradationAtTwoThirdsThreshold() {
        XCTAssertTrue(policy.isDegrading(PathQuality(rttMs: 200, lossPct: 0, samples: 5)))
        XCTAssertFalse(policy.isDegrading(PathQuality(rttMs: 150, lossPct: 0, samples: 5)))
    }

    func testLossDegradationAtHalfThreshold() {
        XCTAssertTrue(policy.isDegrading(PathQuality(rttMs: 40, lossPct: 10, samples: 5)))
        XCTAssertFalse(policy.isDegrading(PathQuality(rttMs: 40, lossPct: 9, samples: 5)))
    }

    func testBreachImpliesDegradation() {
        let breaching = PathQuality(rttMs: 400, lossPct: 30, samples: 5)
        XCTAssertTrue(policy.isBreaching(breaching))
        XCTAssertTrue(policy.isDegrading(breaching))
    }

    // MARK: - JSON parsing

    func testPathQualityFromGoStateJSON() {
        let dict: [String: Any] = ["rttMs": 123.5, "lossPct": 5, "samples": 20, "lastReplyAgeSec": 1.2]
        let q = PathQuality(dict: dict)
        XCTAssertEqual(q?.rttMs, 123.5)
        XCTAssertEqual(q?.lossPct, 5)
        XCTAssertEqual(q?.samples, 20)
    }

    func testPathQualityFromNilOrEmpty() {
        XCTAssertNil(PathQuality(dict: nil))
        let q = PathQuality(dict: [:])
        XCTAssertEqual(q?.rttMs, -1)
        XCTAssertEqual(q?.lossPct, -1)
        XCTAssertEqual(q?.samples, 0)
    }
}
