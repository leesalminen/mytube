//
//  ParentalControlsStoreTests.swift
//  MyTubeTests
//
//  Created by Assistant on 02/18/26.
//

import XCTest
@testable import MyTube

final class ParentalControlsStoreTests: XCTestCase {
    private func makeStore() -> (ParentalControlsStore, UserDefaults) {
        let suite = "ParentalControlsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ParentalControlsStore(userDefaults: defaults)
        return (store, defaults)
    }

    func testDefaults() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.requiresVideoApproval)
        XCTAssertTrue(store.enableContentScanning)
        XCTAssertNil(store.autoRejectThreshold)
    }

    func testRequiresApprovalForcesScanningOn() {
        let (store, defaults) = makeStore()
        defaults.set(false, forKey: "com.mytube.parental.enableContentScanning")

        store.setRequiresVideoApproval(true)

        XCTAssertTrue(store.requiresVideoApproval)
        XCTAssertTrue(store.enableContentScanning, "Enabling approval should force scanning on")
    }

    func testEnableContentScanningPersistsValue() {
        let (store, _) = makeStore()
        store.setEnableContentScanning(false)
        XCTAssertFalse(store.enableContentScanning)

        store.setEnableContentScanning(true)
        XCTAssertTrue(store.enableContentScanning)
    }

    func testAutoRejectThresholdClampsAndClears() {
        let (store, _) = makeStore()
        store.setAutoRejectThreshold(1.5)
        XCTAssertEqual(store.autoRejectThreshold, 1.0)

        store.setAutoRejectThreshold(-0.2)
        XCTAssertEqual(store.autoRejectThreshold, 0.0)

        store.setAutoRejectThreshold(0.42)
        XCTAssertEqual(store.autoRejectThreshold, 0.42)

        store.setAutoRejectThreshold(nil)
        XCTAssertNil(store.autoRejectThreshold)
    }
}
