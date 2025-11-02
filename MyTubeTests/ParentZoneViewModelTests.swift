//
//  ParentZoneViewModelTests.swift
//  MyTubeTests
//
//  Created by Codex on 11/06/25.
//

import XCTest
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

    func testApprovedParentKeysReturnsActiveFollowParents() throws {
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
            let parentHex = viewModel.parentIdentity?.publicKeyHex,
            let child = viewModel.childIdentities.first(where: { $0.displayName == "Nova" }),
            let childIdentity = child.identity
        else {
            return XCTFail("Expected local parent and child identities")
        }

        let remoteParent = try environment.cryptoService.generateSigningKeyPair()
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()

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
        let remoteChild = try environment.cryptoService.generateSigningKeyPair()
        let remoteParentHex = remoteParent.publicKeyXOnly.hexEncodedString()

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
        let syncCoordinator = SyncCoordinator(
            persistence: persistence,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
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

        let directMessageOutbox = DirectMessageOutbox(
            keyStore: keyStore,
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        let likePublisher = LikePublisher(
            directMessageOutbox: directMessageOutbox,
            keyStore: keyStore,
            childProfileStore: childProfileStore,
            remoteVideoStore: remoteVideoStore
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
            directMessageOutbox: directMessageOutbox,
            keyStore: keyStore,
            parentProfileStore: parentProfileStore
        )
        let videoShareCoordinator = VideoShareCoordinator(
            persistence: persistence,
            keyStore: keyStore,
            relationshipStore: relationshipStore,
            videoSharePublisher: videoSharePublisher
        )

        let followCoordinator = FollowCoordinator(
            identityManager: identityManager,
            relationshipStore: relationshipStore,
            directMessageOutbox: directMessageOutbox,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        let reportCoordinator = ReportCoordinator(
            reportStore: reportStore,
            remoteVideoStore: remoteVideoStore,
            videoLibrary: videoLibrary,
            directMessageOutbox: directMessageOutbox,
            keyStore: keyStore,
            backendClient: backendClient,
            safetyStore: safetyConfigurationStore,
            storagePaths: storagePaths,
            relationshipStore: relationshipStore,
            followCoordinator: followCoordinator
        )

        let activeProfile = try profileStore.createProfile(
            name: "Test Child",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
        )

        return AppEnvironment(
            persistence: persistence,
            storagePaths: storagePaths,
            videoLibrary: videoLibrary,
            remoteVideoStore: remoteVideoStore,
            remoteVideoDownloader: remoteVideoDownloader,
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
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            syncCoordinator: syncCoordinator,
            directMessageOutbox: directMessageOutbox,
            likeStore: likeStore,
            likePublisher: likePublisher,
            storageRouter: storageRouter,
            videoSharePublisher: videoSharePublisher,
            videoShareCoordinator: videoShareCoordinator,
            relationshipStore: relationshipStore,
            followCoordinator: followCoordinator,
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

}
