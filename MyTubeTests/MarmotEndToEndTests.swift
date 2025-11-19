//
//  MarmotEndToEndTests.swift
//  MyTubeTests
//
//  Created by Assistant on 11/18/25.
//

import XCTest
@testable import MyTube

final class MarmotEndToEndTests: XCTestCase {
    func testMinimal() async throws {
        print("\n========== Minimal Test Starting ==========")
        XCTAssertTrue(true)
        print("✅ Minimal test passed")
    }
    
    @MainActor
    func testEnvironmentSetup() async throws {
        print("\n========== Environment Setup Test Starting ==========")
        
        print("👨‍👩‍👧 Setting up Family A environment...")
        let familyA = try await TestFamilyEnvironment(name: "FamilyA")
        print("✅ Family A environment created")
        
        print("🔑 Setting up identity...")
        let _ = try await familyA.setupIdentity()
        print("✅ Identity setup completed")
        
        print("✅ Environment setup test passed")
    }
    
    @MainActor
    func testFullOnboardingAndShareFlow() async throws {
        print("\n========== Marmot End-to-End Test Starting ==========")
        
        print("👨‍👩‍👧 Setting up Family A environment...")
        let familyA = try await TestFamilyEnvironment(name: "FamilyA")
        
        print("👨‍👩‍👧 Setting up Family B environment...")
        let familyB = try await TestFamilyEnvironment(name: "FamilyB")

        print("🔑 Family A: Setting up identity...")
        let profileA = try await familyA.setupIdentity()
        
        print("🔑 Family B: Setting up identity...")
        _ = try await familyB.setupIdentity()

        print("📡 Verifying relay connections...")
        
        // Wait for both families to connect to relays (up to 10 seconds)
        let relayConnected = try await waitUntil("Relay connections established", timeout: 10, pollInterval: 0.5) {
            let statusesA = await familyA.nostrClient.relayStatuses()
            let statusesB = await familyB.nostrClient.relayStatuses()
            let aConnected = statusesA.contains(where: { $0.status == .connected })
            let bConnected = statusesB.contains(where: { $0.status == .connected })
            
            if !aConnected || !bConnected {
                print("   Family A: \(statusesA.map { "\($0.url.absoluteString): \($0.status)" })")
                print("   Family B: \(statusesB.map { "\($0.url.absoluteString): \($0.status)" })")
            }
            
            return aConnected && bConnected
        }
        XCTAssertTrue(relayConnected, "Relays failed to connect")
        print("✅ Both families connected to relays")

        print("🎬 Creating view models...")
        let vmA = familyA.createViewModel()
        let vmB = familyB.createViewModel()

        print("📋 Loading identities...")
        vmA.loadIdentities()
        vmB.loadIdentities()

        guard let childA = vmA.childIdentities.first(where: { $0.id == profileA.id }) else {
            return XCTFail("Family A child identity missing from view model")
        }
        print("✅ Family A child identity loaded: \(childA.profile.name)")

        let parentIdentity = try familyA.environment.identityManager.parentIdentity()
        let childPublicKey = childA.publicKey ?? childA.identity?.keyPair.publicKeyHex
        guard
            let parentIdentity,
            let childPublicKey
        else {
            return XCTFail("Family A identities are incomplete")
        }
        print("✅ Family A parent identity: \(parentIdentity.publicKeyHex.prefix(16))...")
        
        print("📦 Creating key package for Family A...")
        let relays = await familyA.environment.relayDirectory.currentRelayURLs()
        let relayStrings = relays.map(\.absoluteString)
        print("   Using relays: \(relayStrings)")
        let keyPackageResult = try await familyA.environment.mdkActor.createKeyPackage(
            forPublicKey: parentIdentity.publicKeyHex,
            relays: relayStrings
        )
        
        // Encode the key package as a Nostr event
        let keyPackageEvent = try KeyPackageEventEncoder.encode(
            result: keyPackageResult,
            signingKey: parentIdentity.keyPair
        )
        print("✅ Key package created and encoded")
        
        print("💌 Creating follow invite...")
        print("   Family A parent (hex): \(parentIdentity.publicKeyHex.prefix(16))...")
        if let bech32 = parentIdentity.publicKeyBech32 {
            print("   Family A parent (bech32): \(bech32.prefix(16))...")
        }
        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: childA.profile.name,
            childPublicKey: childPublicKey,
            parentPublicKey: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex,
            parentKeyPackages: [keyPackageEvent]
        )
        print("✅ Invite created with \(invite.parentKeyPackages?.count ?? 0) key package(s)")
        print("   Invite parent key: \(invite.parentPublicKey.prefix(16))...")

        print("📥 Family B: Storing pending key packages...")
        vmB.storePendingKeyPackages(from: invite)

        guard let childB = vmB.childIdentities.first else {
            return XCTFail("Family B missing child identity")
        }
        print("✅ Family B child identity: \(childB.profile.name)")

        print("📤 Family B: Submitting follow request...")
        let submissionError = await vmB.submitFollowRequest(
            childId: childB.id,
            targetChildKey: invite.childPublicKey,
            targetParentKey: invite.parentPublicKey
        )
        if let error = submissionError {
            print("   ⚠️ Warning: \(error)")
        }
        print("✅ Follow request submitted")
        
        // Allow time for events to propagate through relays
        print("   Waiting 1s for event propagation...")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        print("⏳ Waiting for Family B to have group created...")
        let groupCreated = try await waitUntil("Family B group created") {
            let groups = try await familyB.environment.mdkActor.getGroups()
            print("   Family B has \(groups.count) group(s)")
            guard let group = groups.first else {
                return false
            }
            let members = try await familyB.environment.mdkActor.getMembers(inGroup: group.mlsGroupId)
            print("   Group: \(group.name), members: \(members.count)")
            return members.count >= 2  // Should have both parents
        }
        XCTAssertTrue(groupCreated)
        print("✅ Family B has group with 2 members")

        print("⏳ Waiting for Family A to receive pending welcome...")
        print("   Family A parent key: \(familyA.parentKey.prefix(16))...")
        print("   Family A child profile ID: \(profileA.id.uuidString)")
        guard let welcome = try await waitForWelcome(viewModel: vmA) else {
            print("   ❌ No welcome received")
            print("   Checking MDK directly...")
            let welcomes = try? await familyA.environment.mdkActor.getPendingWelcomes()
            print("   Direct MDK check: \(welcomes?.count ?? 0) pending welcomes")
            return XCTFail("Family A never received pending welcome")
        }
        print("✅ Family A received welcome: \(welcome.groupName)")

        print("🤝 Family A: Accepting welcome...")
        await vmA.acceptWelcome(welcome, linkToChildId: profileA.id)
        print("✅ Welcome accepted")
        
        // Allow time for acceptance to propagate
        print("   Waiting 1s for acceptance propagation...")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        print("⏳ Waiting for Family A to be in the group...")
        let aInGroup = try await waitUntil("Family A in group") {
            let groups = try await familyA.environment.mdkActor.getGroups()
            print("   Family A has \(groups.count) group(s)")
            guard let group = groups.first else {
                return false
            }
            let members = try await familyA.environment.mdkActor.getMembers(inGroup: group.mlsGroupId)
            print("   Group: \(group.name), members: \(members.count), state: \(group.state)")
            return members.count >= 2 && group.state.lowercased() == "active"
        }
        XCTAssertTrue(aInGroup)
        print("✅ Family A is in active group")

        print("⏳ Verifying both families see each other in group...")
        let groupId = try await familyA.environment.mdkActor.getGroups().first?.mlsGroupId
        XCTAssertNotNil(groupId, "Family A should have a group")
        if let groupId = groupId {
            let membersA = try await familyA.environment.mdkActor.getMembers(inGroup: groupId)
            let membersB = try await familyB.environment.mdkActor.getMembers(inGroup: groupId)
            print("   Family A sees \(membersA.count) members in group")
            print("   Family B sees \(membersB.count) members in group")
            XCTAssertEqual(membersA.count, 2, "Should have 2 members")
            XCTAssertEqual(membersB.count, 2, "Should have 2 members")
        }
        print("✅ Both families in active group")
        
        print("\n========== Marmot End-to-End Test Completed Successfully ==========\n")
    }
}

// MARK: - Helpers

@MainActor
private func waitForWelcome(
    viewModel: ParentZoneViewModel,
    timeout: TimeInterval = 10,
    pollInterval: TimeInterval = 0.25
) async throws -> ParentZoneViewModel.PendingWelcomeItem? {
    let iterations = max(1, Int(timeout / pollInterval))
    for i in 0..<iterations {
        await viewModel.refreshPendingWelcomes()
        print("   [Attempt \(i+1)/\(iterations)] Pending welcomes: \(viewModel.pendingWelcomes.count)")
        if let welcome = viewModel.pendingWelcomes.first {
            return welcome
        }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    print("   ❌ Timed out after \(iterations) attempts")
    XCTFail("Timed out waiting for pending welcome")
    return nil
}

// waitForStatus removed - using MDK group membership instead

private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
    pollInterval: TimeInterval = 0.25,
    condition: @escaping () async throws -> Bool
) async throws -> Bool {
    let iterations = max(1, Int(timeout / pollInterval))
    for _ in 0..<iterations {
        if try await condition() {
            return true
        }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    XCTFail("Timed out waiting for \(description)")
    return false
}
