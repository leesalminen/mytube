//
//  OnboardingFlowViewModelTests.swift
//  MyTubeTests
//
//  Created by Codex on 04/05/26.
//

import XCTest
import NostrSDK
import MDKBindings
@testable import MyTube

@MainActor
final class OnboardingFlowViewModelTests: XCTestCase {
    func testCreateChildUsesChildKeyPackageForGroupMembership() async throws {
        let harness = try makeOnboardingTestEnvironment()
        let environment = harness.environment
        let groupCoordinator = harness.groupMembershipCoordinator
        defer {
            try? environment.storageConfigurationStore.clearBYOConfig()
            try? environment.keyStore.removeAll()
            try? FileManager.default.removeItem(at: environment.storagePaths.rootURL)
        }

        let viewModel = OnboardingFlowView.ViewModel(environment: environment)
        viewModel.startParentSetup(mode: .new)

        guard let parentIdentity = viewModel.parentIdentity else {
            return XCTFail("Expected parent identity to be generated")
        }

        let error = await viewModel.createChild(name: "Luna", theme: .ocean)
        XCTAssertNil(error)

        guard let request = await groupCoordinator.recordedCreateRequest() else {
            return XCTFail("Expected group creation request")
        }
        guard let childEntry = viewModel.childEntries.first(where: { $0.profile.name == "Luna" }) else {
            return XCTFail("Expected child entry to exist")
        }

        let childHex = childEntry.identity.publicKeyHex.lowercased()
        let parentHex = parentIdentity.publicKeyHex.lowercased()

        XCTAssertEqual(request.creatorPublicKeyHex.lowercased(), parentHex)
        XCTAssertEqual(request.memberKeyPackageEventsJson.count, 1)

        let event = try NostrEvent.fromJson(json: request.memberKeyPackageEventsJson[0])
        XCTAssertEqual(event.kind().asU16(), MarmotEventKind.keyPackage.rawValue)
        XCTAssertEqual(event.pubkey.lowercased(), childHex)
        XCTAssertNotEqual(event.pubkey.lowercased(), parentHex)
    }
}

// MARK: - Test Helpers

private struct OnboardingTestHarness {
    let environment: AppEnvironment
    let groupMembershipCoordinator: RecordingGroupMembershipCoordinator
}

@MainActor
private func makeOnboardingTestEnvironment() throws -> OnboardingTestHarness {
    let persistence = PersistenceController(inMemory: true)
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingFlowViewModelTests", isDirectory: true)
    let storagePaths = try StoragePaths(baseURL: tempRoot)
    let parentKeyPackageStore = ParentKeyPackageStore(
        fileURL: storagePaths.parentKeyPackageCacheURL()
    )

    let userDefaults = UserDefaults(suiteName: "OnboardingFlowViewModelTests.Settings")!
    let parentalControlsStore = ParentalControlsStore(userDefaults: userDefaults)
    let videoContentScanner = VideoContentScanner()
    let videoLibrary = VideoLibrary(
        persistence: persistence,
        storagePaths: storagePaths,
        parentalControlsStore: parentalControlsStore,
        contentScanner: videoContentScanner
    )
    let remoteVideoStore = RemoteVideoStore(persistence: persistence)
    let profileStore = ProfileStore(persistence: persistence)
    let thumbnailer = Thumbnailer(storagePaths: storagePaths)
    let editRenderer = EditRenderer(storagePaths: storagePaths)
    let parentAuth = ParentAuth()
    let rankingEngine = RankingEngine()
    let keyStore = KeychainKeyStore(service: "OnboardingFlowViewModelTests.\(UUID().uuidString)")
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
    let groupMembershipCoordinator = RecordingGroupMembershipCoordinator()
    let syncCoordinator = SyncCoordinator(
        persistence: persistence,
        nostrClient: nostrClient,
        relayDirectory: relayDirectory,
        marmotTransport: marmotTransport,
        mdkActor: mdkActor,
        keyStore: keyStore,
        cryptoService: cryptoService,
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
        keyStore: keyStore
    )
    let videoShareCoordinator = VideoShareCoordinator(
        persistence: persistence,
        keyStore: keyStore,
        videoSharePublisher: videoSharePublisher,
        marmotShareService: marmotShareService,
        parentalControlsStore: parentalControlsStore,
        mdkActor: mdkActor
    )

    let reportCoordinator = ReportCoordinator(
        reportStore: reportStore,
        remoteVideoStore: remoteVideoStore,
        marmotShareService: marmotShareService,
        keyStore: keyStore,
        storagePaths: storagePaths,
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

    let environment = AppEnvironment(
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
        parentKeyPackageStore: parentKeyPackageStore,
        groupMembershipCoordinator: groupMembershipCoordinator,
        reportStore: reportStore,
        reportCoordinator: reportCoordinator,
        backendClient: backendClient,
        storageConfigurationStore: storageConfigurationStore,
        safetyConfigurationStore: safetyConfigurationStore,
        parentalControlsStore: parentalControlsStore,
        videoContentScanner: videoContentScanner,
        managedStorageClient: managedStorageClient,
        byoStorageClient: minioClient,
        backendBaseURL: URL(string: "https://example.com")!,
        activeProfile: activeProfile,
        userDefaults: userDefaults,
        onboardingState: .ready,
        storageModeSelection: .byo
    )

    return OnboardingTestHarness(environment: environment, groupMembershipCoordinator: groupMembershipCoordinator)
}

private actor RecordingGroupMembershipCoordinator: GroupMembershipCoordinating {
    private(set) var lastCreateRequest: GroupMembershipCoordinator.CreateGroupRequest?

    func recordedCreateRequest() -> GroupMembershipCoordinator.CreateGroupRequest? {
        lastCreateRequest
    }

    func createGroup(
        request: GroupMembershipCoordinator.CreateGroupRequest
    ) async throws -> GroupMembershipCoordinator.CreateGroupResponse {
        lastCreateRequest = request
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
