// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import XCTest

class UAPITests: XCTestCase {

    func testParseTxRxBytesSumsAcrossPeers() {
        let config = """
        private_key=abc
        public_key=peer1
        tx_bytes=100
        rx_bytes=50
        public_key=peer2
        tx_bytes=200
        rx_bytes=75
        """
        let (tx, rx) = UAPI.parseTxRxBytes(from: config)
        XCTAssertEqual(tx, 300)
        XCTAssertEqual(rx, 125)
    }

    func testParseTxRxBytesEmptyConfig() {
        let (tx, rx) = UAPI.parseTxRxBytes(from: "")
        XCTAssertEqual(tx, 0)
        XCTAssertEqual(rx, 0)
    }

    func testParseTxRxBytesIgnoresMalformedValues() {
        let config = "tx_bytes=notanumber\nrx_bytes=42"
        let (tx, rx) = UAPI.parseTxRxBytes(from: config)
        XCTAssertEqual(tx, 0)
        XCTAssertEqual(rx, 42)
    }

    func testParseLastHandshakeAgePicksLatestPeer() {
        let now = Date().timeIntervalSince1970
        let config = """
        last_handshake_time_sec=\(Int(now - 300))
        last_handshake_time_sec=\(Int(now - 10))
        """
        let age = UAPI.parseLastHandshakeAge(from: config)
        XCTAssertGreaterThanOrEqual(age, 9)
        XCTAssertLessThan(age, 15)
    }

    func testParseLastHandshakeAgeNoHandshake() {
        XCTAssertEqual(UAPI.parseLastHandshakeAge(from: "tx_bytes=1"), .infinity)
        XCTAssertEqual(UAPI.parseLastHandshakeAge(from: "last_handshake_time_sec=0"), .infinity)
    }

    func testRedactSecrets() {
        let config = """
        private_key=deadbeef
        public_key=cafebabe
        preshared_key=secret
        endpoint=1.2.3.4:51820
        """
        let redacted = UAPI.redactSecrets(from: config)
        XCTAssertFalse(redacted.contains("deadbeef"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("private_key=<redacted>"))
        XCTAssertTrue(redacted.contains("preshared_key=<redacted>"))
        XCTAssertTrue(redacted.contains("public_key=cafebabe"))
        XCTAssertTrue(redacted.contains("endpoint=1.2.3.4:51820"))
    }
}
