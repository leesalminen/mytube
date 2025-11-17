//
//  ParentZoneViewModelTests.swift
//  MyTubeTests
//
//  Created by Codex on 11/06/25.
//

import XCTest
import NostrSDK
import MDKBindings
@testable import MyTube

@MainActor
final class ParentZoneViewModelTests: XCTestCase {
    func testAddChildProfileCreatesDelegatedKey() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)

        XCTAssertNil(viewModel.parentIdentity)
        viewModel.createParentIdentity()
        XCTAssertNotNil(viewModel.parentIdentity)

        viewModel.loadIdentities()
        XCTAssertEqual(viewModel.childIdentities.count, 1)
        XCTAssertNil(viewModel.childIdentities.first?.identity)

        viewModel.addChildProfile(name: "Nova", theme: .galaxy)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.childIdentities.count, 2)

        guard let child = viewModel.childIdentities.first(where: { $0.displayName == "Nova" }) else {
            return XCTFail("Expected child identity to be created")
        }
        XCTAssertNotNil(child.secretKey)
        XCTAssertNotNil(child.delegationTag)
    }

    func testRefreshPendingWelcomesLoadsItems() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let welcomeClient = TestWelcomeClient()
        let welcome = makeWelcome(groupName: "Family Fans")
        await welcomeClient.setPendingWelcomes([welcome])

        let viewModel = ParentZoneViewModel(environment: environment, welcomeClient: welcomeClient)
        await viewModel.refreshPendingWelcomes()

        XCTAssertEqual(viewModel.pendingWelcomes.count, 1)
        XCTAssertEqual(viewModel.pendingWelcomes.first?.groupName, "Family Fans")
    }

    func testAcceptWelcomeRemovesInvite() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let welcomeClient = TestWelcomeClient()
        let welcome = makeWelcome(groupName: "Space Squad")
        await welcomeClient.setPendingWelcomes([welcome])

        let viewModel = ParentZoneViewModel(environment: environment, welcomeClient: welcomeClient)
        await viewModel.refreshPendingWelcomes()
        guard let pending = viewModel.pendingWelcomes.first else {
            return XCTFail("Expected pending welcome")
        }

        await viewModel.acceptWelcome(pending)

        XCTAssertTrue(viewModel.pendingWelcomes.isEmpty)
        let accepted = await welcomeClient.acceptedEventJsons()
        XCTAssertEqual(accepted, [welcome.eventJson])
    }

    func testDeclineWelcomeRemovesInvite() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let welcomeClient = TestWelcomeClient()
        let welcome = makeWelcome(groupName: "Neighbor Crew")
        await welcomeClient.setPendingWelcomes([welcome])

        let viewModel = ParentZoneViewModel(environment: environment, welcomeClient: welcomeClient)
        await viewModel.refreshPendingWelcomes()
        guard let pending = viewModel.pendingWelcomes.first else {
            return XCTFail("Expected pending welcome")
        }

        await viewModel.declineWelcome(pending)

        XCTAssertTrue(viewModel.pendingWelcomes.isEmpty)
        let declined = await welcomeClient.declinedEventJsons()
        XCTAssertEqual(declined, [welcome.eventJson])
    }

    func testAcceptWelcomeActivatesPendingFollow() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let welcomeClient = TestWelcomeClient()
        let viewModel = ParentZoneViewModel(environment: environment, welcomeClient: welcomeClient)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let childItem = viewModel.childIdentities.first,
            let childIdentity = childItem.identity,
            let parentHex = viewModel.parentIdentity?.publicKeyHex
        else {
            return XCTFail("Expected parent and child identities")
        }

        let followerHex = childIdentity.keyPair.publicKeyHex.lowercased()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteChildHex = remoteChild.publicKeyXOnly.hexEncodedString()
        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()

        let followMessage = FollowMessage(
            followerChild: followerHex,
            targetChild: remoteChildHex,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: parentHex,
            timestamp: Date()
        )

        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex]
        )
        viewModel.loadRelationships()

        let welcome = makeWelcome(
            groupName: "Space Squad",
            mlsGroupId: String(repeating: "1", count: 32),
            welcomer: remoteParentHex
        )
        await welcomeClient.setPendingWelcomes([welcome])
        await viewModel.refreshPendingWelcomes()
        guard let pendingWelcome = viewModel.pendingWelcomes.first else {
            return XCTFail("Expected pending welcome")
        }

        await viewModel.acceptWelcome(pendingWelcome)

        let relationships = try environment.relationshipStore.fetchFollowRelationships()
        guard let updated = relationships.first else {
            return XCTFail("Expected follow relationship")
        }
        XCTAssertTrue(updated.approvedTo)
        XCTAssertEqual(updated.status, .active)
        XCTAssertEqual(updated.mlsGroupId, String(repeating: "1", count: 32))
    }

    func testWelcomeNotificationRefreshesPending() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let welcomeClient = TestWelcomeClient()
        let welcome = makeWelcome(groupName: "Galaxy")
        await welcomeClient.setPendingWelcomes([welcome])

        let viewModel = ParentZoneViewModel(environment: environment, welcomeClient: welcomeClient)
        XCTAssertTrue(viewModel.pendingWelcomes.isEmpty)

        NotificationCenter.default.post(name: .marmotPendingWelcomesDidChange, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.pendingWelcomes.count, 1)
    }

    func testMarmotStateNotificationRefreshesDiagnosticsAndIdentities() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        await connectStubRelays(environment)
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()
        XCTAssertFalse(viewModel.childIdentities.isEmpty)

        let baselineStats = await environment.mdkActor.stats()
        let baselineDiagnostics = MarmotDiagnostics(
            groupCount: baselineStats.groupCount,
            pendingWelcomes: baselineStats.pendingWelcomeCount
        )

        viewModel.childIdentities = []
        viewModel.marmotDiagnostics = MarmotDiagnostics(
            groupCount: baselineDiagnostics.groupCount + 5,
            pendingWelcomes: baselineDiagnostics.pendingWelcomes + 2
        )

        NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(viewModel.childIdentities.isEmpty)
        XCTAssertEqual(viewModel.marmotDiagnostics, baselineDiagnostics)
    }

    func testImportChildProfileCreatesDelegation() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()

        let seedChild = try environment.identityManager.createChildIdentity(
            name: "Seed",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
        )

        guard let secret = seedChild.secretKeyBech32 else {
            return XCTFail("Expected seed child to expose nsec")
        }

        viewModel.importChildProfile(name: "Imported", secret: secret, theme: .forest)
        XCTAssertNil(viewModel.errorMessage)

        guard let imported = viewModel.childIdentities.first(where: { $0.displayName == "Imported" }) else {
            return XCTFail("Expected imported child profile")
        }
        XCTAssertNotNil(imported.secretKey)
        XCTAssertNotNil(imported.delegationTag)
    }

    func testShareVideoRemotelyRequiresApprovedFollow() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        await connectStubRelays(environment)
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard let child = viewModel.childIdentities.first(where: { $0.displayName == "Nova" }) else {
            return XCTFail("Expected child identity")
        }

        let video = VideoModel(
            id: UUID(),
            profileId: child.id,
            filePath: "Media/\(UUID().uuidString).mp4",
            thumbPath: "Thumbs/\(UUID().uuidString).jpg",
            title: "Test",
            duration: 10,
            createdAt: Date(),
            lastPlayedAt: nil,
            playCount: 0,
            completionRate: 0,
            replayRate: 0,
            liked: false,
            hidden: false,
            tags: [],
            cvLabels: [],
            faceCount: 0,
            loudness: 0.1,
            reportedAt: nil,
            reportReason: nil
        )

        let remoteParentHex = String(repeating: "d", count: 64)

        do {
            _ = try await viewModel.shareVideoRemotely(video: video, recipientPublicKey: remoteParentHex)
            XCTFail("Expected share to fail without approved followers")
        } catch ParentZoneViewModel.ShareFlowError.noApprovedFollowers {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoteShareStatsReflectRemoteVideoStore() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let child = viewModel.childIdentities.first(where: { $0.displayName == "Nova" }),
            let childIdentity = child.identity,
            let parentHex = viewModel.parentIdentity?.publicKeyHex
        else {
            return XCTFail("Expected local identities")
        }

        let followerHex = childIdentity.keyPair.publicKeyHex.lowercased()
        let remoteChildHex = String(repeating: "e", count: 64)
        let remoteParentHex = String(repeating: "f", count: 64)

        let followMessage = FollowMessage(
            followerChild: followerHex,
            targetChild: remoteChildHex,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: parentHex,
            timestamp: Date()
        )

        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex],
            mlsGroupId: "cafebabe"
        )
        viewModel.loadRelationships()

        try insertRemoteVideo(
            environment: environment,
            ownerKey: remoteChildHex,
            status: .available,
            createdAt: Date()
        )
        try insertRemoteVideo(
            environment: environment,
            ownerKey: remoteChildHex,
            status: .revoked,
            createdAt: Date().addingTimeInterval(-3600)
        )
        try insertRemoteVideo(
            environment: environment,
            ownerKey: remoteChildHex,
            status: .available,
            createdAt: Date().addingTimeInterval(-120)
        )

        NotificationCenter.default.post(
            name: .marmotMessagesDidChange,
            object: nil,
            userInfo: ["mlsGroupId": "cafebabe"]
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.totalAvailableRemoteShares(), 2)
        guard let follow = viewModel.activeFollowConnections().first else {
            return XCTFail("Expected active follow connection")
        }
        guard let stats = viewModel.shareStats(for: follow) else {
            return XCTFail("Expected share stats for follow")
        }
        XCTAssertEqual(stats.availableCount, 2)
        XCTAssertEqual(stats.revokedCount, 1)
        XCTAssertTrue(stats.hasAvailableShares)
    }

    func testApprovedParentKeysReturnsActiveFollowParents() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        await connectStubRelays(environment)
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let parentHex = viewModel.parentIdentity?.publicKeyHex,
            let child = viewModel.childIdentities.first(where: { $0.displayName == "Nova" }),
            let childIdentity = child.identity
        else {
            return XCTFail("Expected local parent and child identities")
        }

        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentPair = try NostrKeyPair(privateKeyData: remoteParent.privateKey)
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()
        let parentKeyPackageEvent = try makeKeyPackageEventJson(signingKeyPair: remoteParentPair)

        let message = FollowMessage(
            followerChild: remoteChild.publicKeyXOnly.hexEncodedString(),
            targetChild: childIdentity.publicKeyHex,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: remoteParentHex,
            timestamp: Date()
        )

        _ = try environment.relationshipStore.upsertFollow(message: message, updatedAt: Date())
        viewModel.followRelationships = try environment.relationshipStore.fetchFollowRelationships()

        let options = viewModel.approvedParentKeys(forChild: child.id)
        XCTAssertTrue(options.contains { $0.caseInsensitiveCompare(remoteParentHex) == .orderedSame })
    }

    func testActivateManagedStorageSwitchesMode() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.activateManagedStorage()

        XCTAssertEqual(environment.storageModeSelection, .managed)
        XCTAssertEqual(viewModel.storageMode, .managed)
    }

    func testActivateBYOStorageSavesConfiguration() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.activateManagedStorage()

        viewModel.byoEndpoint = "https://storage.example.com"
        viewModel.byoBucket = "family-media"
        viewModel.byoRegion = "us-west-2"
        viewModel.byoAccessKey = "AKIA123456"
        viewModel.byoSecretKey = "secret123"
        viewModel.byoPathStyle = false

        viewModel.activateBYOStorage()

        XCTAssertEqual(environment.storageModeSelection, .byo)
        XCTAssertEqual(viewModel.storageMode, .byo)

        let stored = try environment.storageConfigurationStore.loadBYOConfig()
        XCTAssertEqual(stored?.endpoint.absoluteString, "https://storage.example.com")
        XCTAssertEqual(stored?.bucket, "family-media")
        XCTAssertEqual(stored?.region, "us-west-2")
        XCTAssertEqual(stored?.accessKey, "AKIA123456")
        XCTAssertEqual(stored?.secretKey, "secret123")
        XCTAssertEqual(stored?.pathStyle, false)
    }

    func testPendingParentKeyPackagesPersistAcrossSessions() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        let parentKeyHex = String(repeating: "a", count: 64)
        let keyPackageEvent = try makeKeyPackageEventJson()
        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: "Remote",
            childPublicKey: String(repeating: "b", count: 64),
            parentPublicKey: parentKeyHex,
            parentKeyPackages: [keyPackageEvent]
        )
        viewModel.storePendingKeyPackages(from: invite)
        XCTAssertTrue(viewModel.hasPendingKeyPackages(for: parentKeyHex))

        let reopened = ParentZoneViewModel(environment: environment)
        XCTAssertTrue(reopened.hasPendingKeyPackages(for: parentKeyHex))

        let restartedEnvironment = try makeTestEnvironment()
        defer {
            try? restartedEnvironment.storageConfigurationStore.clearBYOConfig()
            try? restartedEnvironment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: restartedEnvironment.storagePaths.rootURL)
        }
        let restarted = ParentZoneViewModel(environment: restartedEnvironment)
        XCTAssertTrue(restarted.hasPendingKeyPackages(for: parentKeyHex))
    }

    func testApplyBackendEndpointUpdatesEnvironment() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.activateManagedStorage()
        viewModel.backendEndpoint = "https://api.mytube.test"
        viewModel.applyBackendEndpoint()
        XCTAssertEqual(environment.backendEndpointString(), "https://api.mytube.test")
    }

    func testSubmitFollowRequestSucceedsWithoutPreexistingLink() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
            Task { await environment.syncCoordinator.stop() }
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()
        await environment.syncCoordinator.refreshRelays()

        guard let childId = viewModel.childIdentities.first(where: { $0.displayName == "Nova" })?.id else {
            return XCTFail("Expected child identity")
        }

        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentPair = try NostrKeyPair(privateKeyData: remoteParent.privateKey)
        let parentKeyPackageEvent = try makeKeyPackageEventJson(signingKeyPair: remoteParentPair)
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()

        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: "Remote",
            childPublicKey: remoteChild.publicKeyXOnly.hexEncodedString(),
            parentPublicKey: remoteParentHex,
            parentKeyPackages: [parentKeyPackageEvent]
        )
        viewModel.storePendingKeyPackages(from: invite)

        let error = await viewModel.submitFollowRequest(
            childId: childId,
            targetChildKey: remoteChild.publicKeyXOnly.hexEncodedString(),
            targetParentKey: remoteParentHex
        )

        XCTAssertNil(error)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.followRelationships.count, 1)
        XCTAssertEqual(viewModel.followRelationships.first?.status, .pending)
    }

    func testApproveFollowRequiresKeyPackages() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let childItem = viewModel.childIdentities.first,
            let childIdentity = childItem.identity
        else {
            return XCTFail("Expected child identity")
        }

        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteChildHex = remoteChild.publicKeyXOnly.hexEncodedString()

        let followMessage = FollowMessage(
            followerChild: remoteChildHex,
            targetChild: childIdentity.keyPair.publicKeyHex,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: remoteParentHex,
            timestamp: Date()
        )
        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex]
        )
        viewModel.loadRelationships()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let follow = viewModel.incomingFollowRequests().first else {
            return XCTFail("Expected incoming follow")
        }

        let error = await viewModel.approveFollow(follow)

        XCTAssertEqual(
            error,
            GroupMembershipWorkflowError.keyPackageMissing.errorDescription
        )
        XCTAssertEqual(
            viewModel.errorMessage,
            GroupMembershipWorkflowError.keyPackageMissing.errorDescription
        )
    }

    func testApproveFollowAddsParentToGroupAndUpdatesFollow() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let childItem = viewModel.childIdentities.first,
            let childIdentity = childItem.identity
        else {
            return XCTFail("Expected identities")
        }

        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentPair = try NostrKeyPair(privateKeyData: remoteParent.privateKey)
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteChildHex = remoteChild.publicKeyXOnly.hexEncodedString()

        let followMessage = FollowMessage(
            followerChild: remoteChildHex,
            targetChild: childIdentity.keyPair.publicKeyHex,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: remoteParentHex,
            timestamp: Date()
        )
        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex]
        )
        viewModel.loadRelationships()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let follow = viewModel.incomingFollowRequests().first else {
            return XCTFail("Expected incoming follow")
        }

        let keyPackage = try makeKeyPackageEventJson(signingKeyPair: remoteParentPair)
        let invite = ParentZoneViewModel.FollowInvite(
            version: 2,
            childName: "Remote",
            childPublicKey: remoteChildHex,
            parentPublicKey: remoteParentHex,
            parentKeyPackages: [keyPackage]
        )
        viewModel.storePendingKeyPackages(from: invite)
        XCTAssertTrue(viewModel.hasPendingKeyPackages(for: remoteParentHex))

        await connectStubRelays(environment)
        let error = await viewModel.approveFollow(follow)

        XCTAssertNil(error)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.hasPendingKeyPackages(for: remoteParentHex))

        guard let updated = viewModel.followRelationships.first else {
            return XCTFail("Expected follow relationship")
        }
        XCTAssertTrue(updated.approvedTo)
        XCTAssertEqual(updated.status, .active)
        XCTAssertNotNil(updated.mlsGroupId)
        XCTAssertTrue(
            updated.participantParentKeys.contains {
                guard let key = ParentIdentityKey(string: $0) else { return false }
                return key.hex.caseInsensitiveCompare(remoteParentHex) == .orderedSame
            }
        )
    }

    func testRevokeFollowRemovesMembersViaCoordinator() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }
        let coordinator = environment.groupMembershipCoordinator as? TestGroupMembershipCoordinator

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let child = viewModel.childIdentities.first,
            let childIdentity = child.identity
        else {
            return XCTFail("Missing child identity")
        }
        let groupId = "group-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try environment.profileStore.updateGroupId(groupId, forProfileId: child.profile.id)
        viewModel.loadIdentities()

        let remoteParentPair = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParentPair.publicKeyXOnly.hexEncodedString()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let followMessage = FollowMessage(
            followerChild: remoteChild.publicKeyXOnly.hexEncodedString(),
            targetChild: childIdentity.keyPair.publicKeyHex,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: remoteParentHex,
            timestamp: Date()
        )
        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex],
            mlsGroupId: groupId
        )
        viewModel.loadRelationships()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let follow = viewModel.followRelationships.first else {
            return XCTFail("Expected follow relationship")
        }

        await connectStubRelays(environment)
        let error = await viewModel.revokeFollow(follow, remoteParentKey: remoteParentHex)
        XCTAssertNil(error)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.followRelationships.first?.status, .revoked)

        let removeCalls = await coordinator?.recordedRemoveCalls()
        XCTAssertEqual(removeCalls?.count, 1)
        XCTAssertEqual(removeCalls?.first?.mlsGroupId, groupId)
        XCTAssertEqual(removeCalls?.first?.memberKeys, [remoteParentHex.lowercased()])
    }

    func testUnblockFamilyRemovesMembers() async throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }
        let coordinator = environment.groupMembershipCoordinator as? TestGroupMembershipCoordinator

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Nova", theme: .ocean)
        viewModel.loadIdentities()

        guard
            let child = viewModel.childIdentities.first,
            let childIdentity = child.identity
        else {
            return XCTFail("Missing child identity")
        }
        let groupId = "group-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try environment.profileStore.updateGroupId(groupId, forProfileId: child.profile.id)
        viewModel.loadIdentities()

        let remoteParentPair = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParentPair.publicKeyXOnly.hexEncodedString()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let followMessage = FollowMessage(
            followerChild: remoteChild.publicKeyXOnly.hexEncodedString(),
            targetChild: childIdentity.keyPair.publicKeyHex,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.blocked.rawValue,
            by: remoteParentHex,
            timestamp: Date()
        )
        _ = try environment.relationshipStore.upsertFollow(
            message: followMessage,
            updatedAt: Date(),
            participantKeys: [remoteParentHex],
            mlsGroupId: groupId
        )
        viewModel.loadRelationships()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let follow = viewModel.followRelationships.first else {
            return XCTFail("Expected follow relationship")
        }

        await connectStubRelays(environment)
        viewModel.unblockFamily(for: follow)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(viewModel.followRelationships.first?.status, .revoked)

        let removeCalls = await coordinator?.recordedRemoveCalls()
        XCTAssertEqual(removeCalls?.count, 1)
        XCTAssertEqual(removeCalls?.first?.mlsGroupId, groupId)
        XCTAssertEqual(removeCalls?.first?.memberKeys, [remoteParentHex.lowercased()])
    }

    func testChildDeviceInviteEncodingAndDecoding() throws {
        let environment = try makeTestEnvironment()
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = ParentZoneViewModel(environment: environment)
        viewModel.createParentIdentity()
        viewModel.addChildProfile(name: "Comet", theme: .forest)

        guard let child = viewModel.childIdentities.first(where: { $0.displayName == "Comet" }) else {
            return XCTFail("Expected child identity to exist")
        }
        guard let invite = viewModel.childDeviceInvite(for: child) else {
            return XCTFail("Expected child device invite")
        }
        guard let encodedURL = invite.encodedURL else {
            return XCTFail("Expected encoded invite URL")
        }

        let decodedFromURL = ParentZoneViewModel.ChildDeviceInvite.decode(from: encodedURL)
        XCTAssertEqual(decodedFromURL, invite)

        let decodedFromShareText = ParentZoneViewModel.ChildDeviceInvite.decode(from: invite.shareText)
        XCTAssertEqual(decodedFromShareText, invite)

        XCTAssertFalse(invite.shareItems.isEmpty)
    }

    private func makeTestEnvironment() throws -> AppEnvironment {
        let persistence = PersistenceController(inMemory: true)
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ParentZoneViewModelTests", isDirectory: true)
        let storagePaths = try StoragePaths(baseURL: tempRoot)
        let parentKeyPackageStore = ParentKeyPackageStore(
            fileURL: storagePaths.parentKeyPackageCacheURL()
        )

        let videoLibrary = VideoLibrary(persistence: persistence, storagePaths: storagePaths)
        let remoteVideoStore = RemoteVideoStore(persistence: persistence)
        let profileStore = ProfileStore(persistence: persistence)
        let thumbnailer = Thumbnailer(storagePaths: storagePaths)
        let editRenderer = EditRenderer(storagePaths: storagePaths)
        let parentAuth = ParentAuth()
        let rankingEngine = RankingEngine()
        let keyStore = KeychainKeyStore(service: "ParentZoneViewModelTests")
        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)
        let parentProfileStore = ParentProfileStore(persistence: persistence)
        let childProfileStore = ChildProfileStore(persistence: persistence)
        let remotePlaybackStore = RemotePlaybackStore(persistence: persistence)
        let likeStore = LikeStore(
            persistenceController: persistence,
            childProfileStore: childProfileStore
        )
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = StubNostrClient()
        let userDefaults = UserDefaults(suiteName: "ParentZoneViewModelTests.Settings")!
        let relayDirectory = RelayDirectory(userDefaults: userDefaults)

        let parentProfilePublisher = ParentProfilePublisher(
            identityManager: identityManager,
            parentProfileStore: parentProfileStore,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        let childProfilePublisher = ChildProfilePublisher(
            identityManager: identityManager,
            childProfileStore: childProfileStore,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        let relationshipStore = RelationshipStore(persistence: persistence)
        let reportStore = ReportStore(persistence: persistence)
        let mdkActor = try MdkActor(storagePaths: storagePaths)
        let marmotTransport = MarmotTransport(
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            mdkActor: mdkActor,
            keyStore: keyStore,
            cryptoService: cryptoService
        )
        let marmotShareService = MarmotShareService(
            mdkActor: mdkActor,
            transport: marmotTransport,
            keyStore: keyStore
        )
        let marmotProjectionStore = MarmotProjectionStore(
            mdkActor: mdkActor,
            remoteVideoStore: remoteVideoStore,
            likeStore: likeStore,
            reportStore: reportStore,
            storagePaths: storagePaths,
            notificationCenter: .default,
            userDefaults: userDefaults
        )
        let groupMembershipCoordinator = TestGroupMembershipCoordinator()
        let syncCoordinator = SyncCoordinator(
            persistence: persistence,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            marmotTransport: marmotTransport,
            keyStore: keyStore,
            cryptoService: cryptoService,
            relationshipStore: relationshipStore,
            parentProfileStore: parentProfileStore,
            childProfileStore: childProfileStore,
            likeStore: likeStore,
            reportStore: reportStore,
            remoteVideoStore: remoteVideoStore,
            videoLibrary: videoLibrary,
            storagePaths: storagePaths
        )

        let likePublisher = LikePublisher(
            marmotShareService: marmotShareService,
            keyStore: keyStore,
            childProfileStore: childProfileStore,
            remoteVideoStore: remoteVideoStore,
            relationshipStore: relationshipStore
        )

        let backendClient = BackendClient(
            baseURL: URL(string: "https://example.com")!,
            keyStore: keyStore
        )
        let storageConfigurationStore = StorageConfigurationStore(userDefaults: userDefaults)
        let managedStorageClient = ManagedStorageClient(backend: backendClient)
        let safetyConfigurationStore = SafetyConfigurationStore(userDefaults: userDefaults)

        let byoConfig = UserStorageConfig(
            endpoint: URL(string: "https://example.com")!,
            bucket: "test-bucket",
            region: "us-east-1",
            accessKey: "test-access",
            secretKey: "test-secret",
            pathStyle: true
        )
        try storageConfigurationStore.saveBYOConfig(byoConfig)
        storageConfigurationStore.setMode(.byo)

        let minioClient = MinIOClient(
            configuration: MinIOConfiguration(
                apiBaseURL: byoConfig.endpoint,
                bucket: byoConfig.bucket,
                accessKey: byoConfig.accessKey,
                secretKey: byoConfig.secretKey,
                region: byoConfig.region,
                pathStyle: byoConfig.pathStyle
            )
        )
        let storageRouter = StorageRouter(initialClient: minioClient)

        let remoteVideoDownloader = RemoteVideoDownloader(
            persistence: persistence,
            storagePaths: storagePaths,
            keyStore: keyStore,
            cryptoService: cryptoService,
            storageClient: storageRouter
        )
        let videoSharePublisher = VideoSharePublisher(
            storagePaths: storagePaths,
            cryptoService: cryptoService,
            storageClient: storageRouter,
            keyStore: keyStore
        )
        let videoShareCoordinator = VideoShareCoordinator(
            persistence: persistence,
            keyStore: keyStore,
            relationshipStore: relationshipStore,
            videoSharePublisher: videoSharePublisher,
            marmotShareService: marmotShareService
        )

        let reportCoordinator = ReportCoordinator(
            reportStore: reportStore,
            remoteVideoStore: remoteVideoStore,
            marmotShareService: marmotShareService,
            keyStore: keyStore,
            storagePaths: storagePaths,
            relationshipStore: relationshipStore,
            groupMembershipCoordinator: groupMembershipCoordinator
        )

        let activeProfile = try profileStore.createProfile(
            name: "Test Child",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
        )

        Task {
            await marmotProjectionStore.start()
        }

        return AppEnvironment(
            persistence: persistence,
            storagePaths: storagePaths,
            videoLibrary: videoLibrary,
            remoteVideoStore: remoteVideoStore,
            remoteVideoDownloader: remoteVideoDownloader,
            remotePlaybackStore: remotePlaybackStore,
            profileStore: profileStore,
            thumbnailer: thumbnailer,
            editRenderer: editRenderer,
            parentAuth: parentAuth,
            rankingEngine: rankingEngine,
            keyStore: keyStore,
            identityManager: identityManager,
            parentProfileStore: parentProfileStore,
            parentProfilePublisher: parentProfilePublisher,
            childProfilePublisher: childProfilePublisher,
            childProfileStore: childProfileStore,
            mdkActor: mdkActor,
            marmotTransport: marmotTransport,
            marmotShareService: marmotShareService,
            marmotProjectionStore: marmotProjectionStore,
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            syncCoordinator: syncCoordinator,
            likeStore: likeStore,
            likePublisher: likePublisher,
            storageRouter: storageRouter,
            videoSharePublisher: videoSharePublisher,
            videoShareCoordinator: videoShareCoordinator,
            relationshipStore: relationshipStore,
            parentKeyPackageStore: parentKeyPackageStore,
            groupMembershipCoordinator: groupMembershipCoordinator,
            reportStore: reportStore,
            reportCoordinator: reportCoordinator,
            backendClient: backendClient,
            storageConfigurationStore: storageConfigurationStore,
            safetyConfigurationStore: safetyConfigurationStore,
            managedStorageClient: managedStorageClient,
            byoStorageClient: minioClient,
            backendBaseURL: URL(string: "https://example.com")!,
            activeProfile: activeProfile,
            userDefaults: userDefaults,
            onboardingState: .ready,
            storageModeSelection: .byo
        )
    }

    private func insertRemoteVideo(
        environment: AppEnvironment,
        ownerKey: String,
        status: RemoteVideoModel.Status,
        createdAt: Date
    ) throws {
        let context = environment.persistence.viewContext
        let entity = RemoteVideoEntity(context: context)
        entity.videoId = UUID().uuidString
        entity.ownerChild = ownerKey
        entity.title = "Shared Video"
        entity.duration = 10
        entity.createdAt = createdAt
        entity.blobURL = "https://cdn.example.com/blob/\(UUID().uuidString)"
        entity.thumbURL = "https://cdn.example.com/thumb/\(UUID().uuidString)"
        entity.visibility = "followers"
        entity.status = status.rawValue
        entity.metadataJSON = "{}"
        entity.lastSyncedAt = createdAt
        try context.save()
    }

    private func connectStubRelays(_ environment: AppEnvironment) async {
        await environment.syncCoordinator.refreshRelays()
    }

}

private actor TestGroupMembershipCoordinator: GroupMembershipCoordinating {
    struct RemoveCall {
        let mlsGroupId: String
        let memberKeys: [String]
    }

    private(set) var removeCalls: [RemoveCall] = []

    func recordedRemoveCalls() -> [RemoveCall] {
        removeCalls
    }

    func createGroup(
        request: GroupMembershipCoordinator.CreateGroupRequest
    ) async throws -> GroupMembershipCoordinator.CreateGroupResponse {
        let groupId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let group = Group(
            mlsGroupId: groupId,
            nostrGroupId: String(repeating: "0", count: 64),
            name: request.name,
            description: request.description,
            imageHash: nil,
            imageKey: nil,
            imageNonce: nil,
            adminPubkeys: request.adminPublicKeys,
            lastMessageId: nil,
            lastMessageAt: nil,
            epoch: 0,
            state: "active"
        )
        let result = CreateGroupResult(group: group, welcomeRumorsJson: [])
        let publish = MarmotTransport.CreateGroupPublishResult(groupId: groupId, welcomeGiftWraps: [])
        return GroupMembershipCoordinator.CreateGroupResponse(result: result, publishResult: publish)
    }

    func addMembers(
        request: GroupMembershipCoordinator.AddMembersRequest
    ) async throws -> GroupMembershipCoordinator.AddMembersResponse {
        let evolutionEvent = try makeStubEvent()
        let result = AddMembersResult(
            evolutionEventJson: try evolutionEvent.asJson(),
            welcomeRumorsJson: nil,
            mlsGroupId: request.mlsGroupId
        )
        let publish = MarmotTransport.MemberUpdatePublishResult(
            groupId: request.mlsGroupId,
            evolutionEvent: evolutionEvent,
            welcomeGiftWraps: []
        )
        return GroupMembershipCoordinator.AddMembersResponse(result: result, publishResult: publish)
    }

    func removeMembers(
        request: GroupMembershipCoordinator.RemoveMembersRequest
    ) async throws -> GroupMembershipCoordinator.RemoveMembersResponse {
        removeCalls.append(RemoveCall(mlsGroupId: request.mlsGroupId, memberKeys: request.memberPublicKeys))
        let evolutionEvent = try makeStubEvent()
        let result = GroupUpdateResult(
            evolutionEventJson: try evolutionEvent.asJson(),
            welcomeRumorsJson: nil,
            mlsGroupId: request.mlsGroupId
        )
        let publish = MarmotTransport.MemberRemovalPublishResult(
            groupId: request.mlsGroupId,
            evolutionEvent: evolutionEvent
        )
        return GroupMembershipCoordinator.RemoveMembersResponse(result: result, publishResult: publish)
    }

    private func makeStubEvent() throws -> NostrEvent {
        let signer = NostrEventSigner()
        let pair = try NostrKeyPair(secretKey: SecretKey.generate())
        let textNoteKind = EventKind(kind: UInt16(1))
        return try signer.makeEvent(kind: textNoteKind, tags: [], content: "stub", keyPair: pair)
    }
}

private actor TestWelcomeClient: WelcomeHandling {
    private var pendingWelcomes: [Welcome]
    private var accepted: [String] = []
    private var declined: [String] = []

    init(welcomes: [Welcome] = []) {
        self.pendingWelcomes = welcomes
    }

    func setPendingWelcomes(_ welcomes: [Welcome]) {
        pendingWelcomes = welcomes
    }

    func getPendingWelcomes() throws -> [Welcome] {
        pendingWelcomes
    }

    func acceptWelcome(welcomeJson: String) throws {
        accepted.append(welcomeJson)
        pendingWelcomes.removeAll { $0.eventJson == welcomeJson }
    }

    func declineWelcome(welcomeJson: String) throws {
        declined.append(welcomeJson)
        pendingWelcomes.removeAll { $0.eventJson == welcomeJson }
    }

    func acceptedEventJsons() -> [String] {
        accepted
    }

    func declinedEventJsons() -> [String] {
        declined
    }
}

private func makeWelcome(
    id: String = UUID().uuidString,
    groupName: String = "Family",
    mlsGroupId: String = String(repeating: "a", count: 32),
    welcomer: String = String(repeating: "c", count: 64)
) -> Welcome {
    Welcome(
        id: id,
        eventJson: #"{"id":"\#(id)"}"#,
        mlsGroupId: mlsGroupId,
        nostrGroupId: String(repeating: "b", count: 64),
        groupName: groupName,
        groupDescription: "Sample group",
        groupImageHash: nil,
        groupImageKey: nil,
        groupImageNonce: nil,
        groupAdminPubkeys: [],
        groupRelays: ["wss://relay.test"],
        welcomer: welcomer,
        memberCount: 2,
        state: "pending",
        wrapperEventId: String(repeating: "d", count: 64)
    )
}

private func makeKeyPackageEventJson(
    signingKeyPair: NostrKeyPair? = nil,
    relays: [String] = ["wss://relay.test"],
    content: String = String(repeating: "a", count: 64)
) throws -> String {
    let pair = try signingKeyPair ?? NostrKeyPair(secretKey: SecretKey.generate())
    let relayTag: Tag
    if let first = relays.first {
        relayTag = NostrTagBuilder.make(
            name: "relays",
            value: first,
            otherParameters: Array(relays.dropFirst())
        )
    } else {
        relayTag = NostrTagBuilder.make(name: "relays", value: "wss://relay.test")
    }
    let event = try NostrEventSigner().makeEvent(
        kind: MarmotEventKind.keyPackage.nostrKind,
        tags: [relayTag],
        content: content,
        keyPair: pair
    )
    return try event.asJson()
}
