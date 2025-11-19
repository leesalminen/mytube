//
//  SimpleMarmotTest.swift
//  MyTubeTests
//
//  Created by Assistant on 11/18/25.
//

import XCTest
@testable import MyTube

final class SimpleMarmotTest: XCTestCase {
    @MainActor
    func testBasicSetup() async throws {
        print("\n🧪 Testing basic Marmot setup...")
        
        let familyA = try await TestFamilyEnvironment(name: "FamilyA")
        print("✅ Created Family A environment")
        
        let profileA = try await familyA.setupIdentity()
        print("✅ Created Family A identity: \(profileA.name)")
        
        let vmA = familyA.createViewModel()
        vmA.loadIdentities()
        print("✅ Loaded identities, found \(vmA.childIdentities.count) child(ren)")
        
        guard let childA = vmA.childIdentities.first(where: { $0.id == profileA.id }) else {
            return XCTFail("Child identity not found")
        }
        
        guard let parentIdentity = try familyA.environment.identityManager.parentIdentity() else {
            return XCTFail("Parent identity not found")
        }
        
        print("✅ Parent key: \(parentIdentity.publicKeyHex.prefix(16))...")
        print("✅ Child key: \(childA.publicKey?.prefix(16) ?? "none")...")
        
        // Try creating a key package
        let relays = await familyA.environment.relayDirectory.currentRelayURLs()
        print("✅ Found \(relays.count) relay(s)")
        
        let keyPackageResult = try await familyA.environment.mdkActor.createKeyPackage(
            forPublicKey: parentIdentity.publicKeyHex,
            relays: relays.map(\.absoluteString)
        )
        print("✅ Created key package")
        
        // Check MDK stats
        let stats = await familyA.environment.mdkActor.stats()
        print("✅ MDK stats: \(stats.groupCount) group(s), \(stats.pendingWelcomeCount) pending welcome(s)")
        
        print("🎉 Basic setup test passed!\n")
    }
    
    @MainActor
    func testFollowRequestSubmission() async throws {
        print("\n🧪 Testing follow request submission...")
        
        let familyA = try await TestFamilyEnvironment(name: "FamilyA")
        let familyB = try await TestFamilyEnvironment(name: "FamilyB")
        print("✅ Created both families")
        
        let profileA = try await familyA.setupIdentity()
        _ = try await familyB.setupIdentity()
        print("✅ Setup identities")
        
        let vmA = familyA.createViewModel()
        let vmB = familyB.createViewModel()
        vmA.loadIdentities()
        vmB.loadIdentities()
        print("✅ Loaded view models")
        
        guard let childA = vmA.childIdentities.first(where: { $0.id == profileA.id }),
              let childB = vmB.childIdentities.first,
              let parentIdentity = try familyA.environment.identityManager.parentIdentity(),
              let childPublicKey = childA.publicKey else {
            return XCTFail("Missing required identities")
        }
        print("✅ Got all identities")
        
        // Create invite
        let relays = await familyA.environment.relayDirectory.currentRelayURLs()
        let keyPackageResult = try await familyA.environment.mdkActor.createKeyPackage(
            forPublicKey: parentIdentity.publicKeyHex,
            relays: relays.map(\.absoluteString)
        )
        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: childA.profile.name,
            childPublicKey: childPublicKey,
            parentPublicKey: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex,
            parentKeyPackages: [keyPackageResult.keyPackage]
        )
        vmB.storePendingKeyPackages(from: invite)
        print("✅ Created and stored invite")
        
        // Submit follow request
        print("📤 Submitting follow request...")
        let error = await vmB.submitFollowRequest(
            childId: childB.id,
            targetChildKey: invite.childPublicKey,
            targetParentKey: invite.parentPublicKey
        )
        
        XCTAssertNil(error, "Follow request should not fail, but got: \(error ?? "unknown")")
        print("✅ Follow request submitted without error")
        
        // Give it a moment to process
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Check if group was created
        do {
            let groups = try await familyB.environment.mdkActor.getGroups()
            print("✅ Family B has \(groups.count) group(s)")
            
            if let group = groups.first {
                print("   Group name: \(group.name)")
                print("   Group state: \(group.state)")
                let members = try await familyB.environment.mdkActor.getMembers(inGroup: group.mlsGroupId)
                print("   Members: \(members.count)")
            }
            
            XCTAssertGreaterThan(groups.count, 0, "Should have at least one group")
            if let group = groups.first {
                let members = try await familyB.environment.mdkActor.getMembers(inGroup: group.mlsGroupId)
                XCTAssertGreaterThanOrEqual(members.count, 2, "Should have at least 2 members")
            }
        } catch {
            print("❌ Error fetching groups: \(error)")
            throw error
        }
        
        print("🎉 Follow request submission test passed!\n")
    }
    
    @MainActor
    func testKeyPackageStorage() async throws {
        print("\n🧪 Testing key package storage...")
        
        let familyA = try await TestFamilyEnvironment(name: "FamilyA")
        let familyB = try await TestFamilyEnvironment(name: "FamilyB")
        
        _ = try await familyA.setupIdentity()
        _ = try await familyB.setupIdentity()
        
        let vmA = familyA.createViewModel()
        let vmB = familyB.createViewModel()
        vmA.loadIdentities()
        vmB.loadIdentities()
        
        guard let parentIdentity = try familyA.environment.identityManager.parentIdentity() else {
            return XCTFail("Missing parent identity")
        }
        print("✅ Parent A key: \(parentIdentity.publicKeyHex.prefix(16))...")
        
        // Create key package
        let relays = await familyA.environment.relayDirectory.currentRelayURLs()
        let keyPackageResult = try await familyA.environment.mdkActor.createKeyPackage(
            forPublicKey: parentIdentity.publicKeyHex,
            relays: relays.map(\.absoluteString)
        )
        print("✅ Created key package")
        
        // Create invite
        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: "TestChild",
            childPublicKey: "test_child_key",
            parentPublicKey: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex,
            parentKeyPackages: [keyPackageResult.keyPackage]
        )
        print("✅ Created invite")
        
        // Store key packages
        vmB.storePendingKeyPackages(from: invite)
        print("✅ Stored key packages in Family B")
        
        // Verify storage
        let hasPackages = vmB.hasPendingKeyPackages(for: invite.parentPublicKey)
        print("   Has pending packages for parent: \(hasPackages)")
        
        XCTAssertTrue(hasPackages, "Should have pending key packages after storing")
        print("🎉 Key package storage test passed!\n")
    }
}

