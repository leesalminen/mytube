//
//  IdentityManagerTests.swift
//  MyTubeTests
//
//  Created by Codex on 11/06/25.
//

import XCTest
@testable import MyTube

final class IdentityManagerTests: XCTestCase {
    func testParentAndChildIdentityLifecycle() throws {
        let persistence = PersistenceController(inMemory: true)
        let profileStore = ProfileStore(persistence: persistence)

        let profile = try profileStore.createProfile(
            name: "Test Child",
            theme: .ocean,
            avatarAsset: "avatar.dolphin"
        )

        let keyStore = KeychainKeyStore(service: "IdentityManagerTests.\(UUID().uuidString)")
        defer {
            try? keyStore.removeKeyPair(role: .parent)
        }
        try? keyStore.removeKeyPair(role: .parent)

        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)

        XCTAssertFalse(identityManager.hasParentIdentity())

        let parent = try identityManager.generateParentIdentity(requireBiometrics: false)
        XCTAssertNotNil(parent.publicKeyBech32)
        XCTAssertTrue(identityManager.hasParentIdentity())

        let fetchedParent = try identityManager.parentIdentity()
        XCTAssertEqual(fetchedParent?.publicKeyHex, parent.publicKeyHex)

        // Children are now just profiles without separate keys
        let child = identityManager.childIdentity(for: profile)
        XCTAssertNotNil(child)
        XCTAssertEqual(child?.profile.id, profile.id)
        // Child "public key" is now just the profile ID
        XCTAssertNotNil(child?.publicKeyHex)
        // Children don't have secret keys
        XCTAssertNil(child?.secretKeyBech32)
    }

    func testCreateAndImportChildProfile() throws {
        let persistence = PersistenceController(inMemory: true)
        let profileStore = ProfileStore(persistence: persistence)
        let keyStore = KeychainKeyStore(service: "IdentityManagerTests.\(UUID().uuidString)")
        defer { try? keyStore.removeAll() }

        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)
        _ = try identityManager.generateParentIdentity(requireBiometrics: false)

        let created = try identityManager.createChildIdentity(
            name: "Nova",
            theme: .galaxy,
            avatarAsset: "avatar.dolphin"
        )
        XCTAssertEqual(created.profile.name, "Nova")
        // Children don't have delegations anymore
        XCTAssertNil(created.delegation)
        // Children don't have secret keys
        XCTAssertNil(created.secretKeyBech32)
        
        // Test creating another child profile
        let second = try identityManager.createChildIdentity(
            name: "Nova Backup",
            theme: .ocean,
            avatarAsset: "avatar.dolphin"
        )
        XCTAssertEqual(second.profile.name, "Nova Backup")
        XCTAssertNotEqual(second.publicKeyHex, created.publicKeyHex)  // Different profile IDs
    }
}
