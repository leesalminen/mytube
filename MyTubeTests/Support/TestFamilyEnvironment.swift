//
//  TestFamilyEnvironment.swift
//  MyTubeTests
//
//  Created by Assistant on 11/18/25.
//

import Foundation
@testable import MyTube

@MainActor
class TestFamilyEnvironment {
    let name: String
    let environment: AppEnvironment
    let nostrClient: RelayPoolNostrClient
    let rootURL: URL
    
    var parentKey: String {
        (try? environment.identityManager.parentIdentity())?.publicKeyHex ?? ""
    }
    
    init(name: String) async throws {
        self.name = name
        
        // Setup isolated directory
        let tempDir = FileManager.default.temporaryDirectory
        self.rootURL = tempDir.appendingPathComponent("TestFamily-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        
        let storagePaths = try StoragePaths(baseURL: rootURL)
        let persistence = PersistenceController(inMemory: true)
        
        // Keys
        let keyStore = KeychainKeyStore(service: "TestFamily.\(name).\(UUID().uuidString)")
        let cryptoService = CryptoEnvelopeService()
        
        // User defaults namespaces (isolate per test)
        let defaultsSuite = "Test.\(name).Defaults.\(UUID().uuidString)"
        let storageSuite = "Test.\(name).Storage.\(UUID().uuidString)"
        let safetySuite = "Test.\(name).Safety.\(UUID().uuidString)"
        let relaySuite = "Test.\(name).Relays.\(UUID().uuidString)"
        let parentalSuite = "Test.\(name).Parental.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuite)!
        userDefaults.removePersistentDomain(forName: defaultsSuite)
        let storageDefaults = UserDefaults(suiteName: storageSuite)!
        storageDefaults.removePersistentDomain(forName: storageSuite)
        let safetyDefaults = UserDefaults(suiteName: safetySuite)!
        safetyDefaults.removePersistentDomain(forName: safetySuite)
        let relayDefaults = UserDefaults(suiteName: relaySuite)!
        relayDefaults.removePersistentDomain(forName: relaySuite)
        let parentalDefaults = UserDefaults(suiteName: parentalSuite)!
        parentalDefaults.removePersistentDomain(forName: parentalSuite)

        // Nostr - using real relay for end-to-end testing
        self.nostrClient = RelayPoolNostrClient()
        let relayDirectory = RelayDirectory(userDefaults: relayDefaults)
        
        // Configure to use wss://no.str.cr for testing
        let testRelayURL = URL(string: "wss://no.str.cr")!
        await relayDirectory.replaceAll(with: [testRelayURL])
        
        // Connect to relay
        try? await nostrClient.connect(relays: [testRelayURL])
        
        // Wait a moment for connection to establish
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // Identity & Profiles
        let profileStore = ProfileStore(persistence: persistence)
        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)
        let parentProfileStore = ParentProfileStore(persistence: persistence)
        let childProfileStore = ChildProfileStore(persistence: persistence)
        
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
        
        // Marmot Core
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
        
        // Stores
        let reportStore = ReportStore(persistence: persistence)
        let remoteVideoStore = RemoteVideoStore(persistence: persistence)
        let likeStore = LikeStore(persistenceController: persistence, childProfileStore: childProfileStore)
        let remotePlaybackStore = RemotePlaybackStore(persistence: persistence)
        
        // Coordinators
        let groupMembershipCoordinator = GroupMembershipCoordinator(
            mdkActor: mdkActor,
            marmotTransport: marmotTransport
        )
        
        let parentKeyPackageStore = ParentKeyPackageStore(
            fileURL: storagePaths.parentKeyPackageCacheURL()
        )
        
        // Other required components (stubs or minimal impls)
        let parentalControlsStore = ParentalControlsStore(userDefaults: parentalDefaults)
        let videoContentScanner = VideoContentScanner()
        let videoLibrary = VideoLibrary(
            persistence: persistence,
            storagePaths: storagePaths,
            parentalControlsStore: parentalControlsStore,
            contentScanner: videoContentScanner
        )
        let thumbnailer = Thumbnailer(storagePaths: storagePaths)
        let editRenderer = EditRenderer(storagePaths: storagePaths)
        let parentAuth = ParentAuth()
        let rankingEngine = RankingEngine()
        let backendClient = BackendClient(baseURL: URL(string: "https://example.com")!, keyStore: keyStore)
        let storageConfig = StorageConfigurationStore(userDefaults: storageDefaults)
        storageConfig.setMode(.byo)
        let safetyConfig = SafetyConfigurationStore(userDefaults: safetyDefaults)
        
        // Storage (Simulated)
        let minioConfiguration = MinIOConfiguration(
            apiBaseURL: URL(string: "https://s3.example.com")!,
            bucket: "test-bucket",
            accessKey: "test-access",
            secretKey: "test-secret",
            region: "us-east-1",
            pathStyle: true
        )
        let minio = MinIOClient(configuration: minioConfiguration)
        let storageRouter = StorageRouter(initialClient: minio)
        let managedStorageClient = ManagedStorageClient(backend: backendClient)
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
        
        let marmotProjectionStore = MarmotProjectionStore(
            mdkActor: mdkActor,
            remoteVideoStore: remoteVideoStore,
            likeStore: likeStore,
            reportStore: reportStore,
            storagePaths: storagePaths,
            notificationCenter: NotificationCenter(),
            userDefaults: userDefaults
        )
        Task {
            await marmotProjectionStore.start()
        }
        
        // Start sync coordinator to subscribe to Nostr events
        Task {
            await syncCoordinator.start()
        }

        let defaultProfile = try profileStore.createProfile(
            name: "\(name) Default",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
        )

        self.environment = AppEnvironment(
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
            storageConfigurationStore: storageConfig,
            safetyConfigurationStore: safetyConfig,
            parentalControlsStore: parentalControlsStore,
            videoContentScanner: videoContentScanner,
            managedStorageClient: managedStorageClient,
            byoStorageClient: minio,
            backendBaseURL: URL(string: "https://api.example.com")!,
            activeProfile: defaultProfile,
            userDefaults: userDefaults,
            onboardingState: .ready,
            storageModeSelection: .byo
        )
    }
    
    func setupIdentity() async throws -> ProfileModel {
        // Generate parent identity
        _ = try environment.identityManager.generateParentIdentity(requireBiometrics: false)
        
        // Create child profile and identity
        let profile = try environment.profileStore.createProfile(
            name: "\(name) Child",
            theme: .ocean,
            avatarAsset: "avatar_1"
        )
        
        // Generate keys for child
        _ = try environment.identityManager.ensureChildIdentity(for: profile)
        
        // Refresh subscriptions so the sync coordinator tracks new keys
        await environment.syncCoordinator.refreshSubscriptions()
        
        return profile
    }
    
    func createViewModel() -> ParentZoneViewModel {
        return ParentZoneViewModel(environment: environment)
    }
}
