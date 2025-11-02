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
            try? keyStore.removeKeyPair(role: .child(id: profile.id))
        }
        try? keyStore.removeKeyPair(role: .parent)
        try? keyStore.removeKeyPair(role: .child(id: profile.id))

        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)

        XCTAssertFalse(identityManager.hasParentIdentity())

        let parent = try identityManager.generateParentIdentity(requireBiometrics: false)
        XCTAssertNotNil(parent.publicKeyBech32)
        XCTAssertTrue(identityManager.hasParentIdentity())

        let fetchedParent = try identityManager.parentIdentity()
        XCTAssertEqual(fetchedParent?.publicKeyHex, parent.publicKeyHex)

        let child = try identityManager.ensureChildIdentity(for: profile)
        XCTAssertNotNil(child.publicKeyBech32)

        if let secret = child.secretKeyBech32 {
            let imported = try identityManager.importChildIdentity(secret, for: profile)
            XCTAssertEqual(imported.publicKeyHex, child.publicKeyHex)
        } else {
            XCTFail("Expected child nsec to be encodable")
        }
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
        XCTAssertNotNil(created.delegation)

        guard let secret = created.secretKeyBech32 else {
            return XCTFail("Expected child nsec")
        }

        let imported = try identityManager.importChildIdentity(
            secret,
            profileName: "Nova Backup",
            theme: .ocean,
            avatarAsset: "avatar.dolphin"
        )
        XCTAssertEqual(imported.profile.name, "Nova Backup")
    }
}
