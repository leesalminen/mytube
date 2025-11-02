//
//  StorageConfigurationStoreTests.swift
//  MyTubeTests
//
//  Created by Codex on 03/09/26.
//

import XCTest
@testable import MyTube

final class StorageConfigurationStoreTests: XCTestCase {
    private var userDefaultsSuite: String!
    private var userDefaults: UserDefaults!
    private var store: StorageConfigurationStore!

    override func setUp() {
        super.setUp()
        userDefaultsSuite = "StorageConfigurationStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuite)!
        store = StorageConfigurationStore(userDefaults: userDefaults)
    }

    override func tearDown() {
        try? store.clearBYOConfig()
        if let suite = userDefaultsSuite {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    func testModePersistsAcrossInstances() {
        XCTAssertEqual(store.currentMode(), .managed)
        store.setMode(.byo)
        XCTAssertEqual(store.currentMode(), .byo)

        let reloaded = StorageConfigurationStore(userDefaults: userDefaults)
        XCTAssertEqual(reloaded.currentMode(), .byo)
    }

    func testSaveAndLoadBYOConfigRoundTrips() throws {
        let config = UserStorageConfig(
            endpoint: URL(string: "https://storage.example.com")!,
            bucket: "media",
            region: "us-west-2",
            accessKey: "ACCESS",
            secretKey: "SECRET",
            pathStyle: false
        )

        try store.saveBYOConfig(config)
        let loaded = try XCTUnwrap(store.loadBYOConfig())
        XCTAssertEqual(loaded, config)

        try store.clearBYOConfig()
        XCTAssertNil(try store.loadBYOConfig())
    }
}
