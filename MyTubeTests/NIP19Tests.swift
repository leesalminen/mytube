//
//  NIP19Tests.swift
//  MyTubeTests
//
//  Created by Codex on 11/06/25.
//

import XCTest
@testable import MyTube

final class NIP19Tests: XCTestCase {
    func testPublicKeyRoundTrip() throws {
        let bytes = Data(repeating: 0xAB, count: 32)
        let encoded = try NIP19.encodePublicKey(bytes)
        XCTAssertTrue(encoded.lowercased().hasPrefix("npub"))

        let decoded = try NIP19.decode(encoded)
        XCTAssertEqual(decoded.kind, .npub)
        XCTAssertEqual(decoded.data, bytes)
    }

    func testPrivateKeyRoundTrip() throws {
        var seed = Data(count: 32)
        for i in 0..<seed.count {
            seed[i] = UInt8(i)
        }

        let encoded = try NIP19.encodePrivateKey(seed)
        XCTAssertTrue(encoded.lowercased().hasPrefix("nsec"))

        let decoded = try NIP19.decode(encoded)
        XCTAssertEqual(decoded.kind, .nsec)
        XCTAssertEqual(decoded.data, seed)
    }

    func testDecodeRejectsUnknownHrp() {
        XCTAssertThrowsError(try NIP19.decode("nprofile1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq")) { error in
            XCTAssertTrue(error is NIP19Error)
        }
    }

    func testEncodeRejectsIncorrectLength() {
        let short = Data([0x01, 0x02])
        XCTAssertThrowsError(try NIP19.encodePublicKey(short)) { error in
            XCTAssertEqual(error as? NIP19Error, .invalidDataLength)
        }
    }
}
