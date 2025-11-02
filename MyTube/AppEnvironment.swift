//
//  AppEnvironment.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation
import Combine

@MainActor
final class AppEnvironment: ObservableObject {
    let persistence: PersistenceController
    let storagePaths: StoragePaths
    let videoLibrary: VideoLibrary
    let remoteVideoStore: RemoteVideoStore
    let remoteVideoDownloader: RemoteVideoDownloader
    let profileStore: ProfileStore
    let thumbnailer: Thumbnailer
    let editRenderer: EditRenderer
    let parentAuth: ParentAuth
    let rankingEngine: RankingEngine
    let keyStore: KeychainKeyStore
    let identityManager: IdentityManager
    let parentProfileStore: ParentProfileStore
    let parentProfilePublisher: ParentProfilePublisher
    let childProfilePublisher: ChildProfilePublisher
    let childProfileStore: ChildProfileStore
    let cryptoService: CryptoEnvelopeService
    let nostrClient: NostrClient
    let relayDirectory: RelayDirectory
    let syncCoordinator: SyncCoordinator
    let directMessageOutbox: DirectMessageOutbox
    let storageRouter: StorageRouter
    let videoSharePublisher: VideoSharePublisher
    let videoShareCoordinator: VideoShareCoordinator
    let relationshipStore: RelationshipStore
    let followCoordinator: FollowCoordinator
    let backendClient: BackendClient
    let storageConfigurationStore: StorageConfigurationStore
    private let managedStorageClient: ManagedStorageClient
    private var byoStorageClient: MinIOClient?
    private var backendBaseURL: URL

    private var cancellables: Set<AnyCancellable> = []

    @Published var onboardingState: OnboardingState
    @Published var storageModeSelection: StorageModeSelection

    let mainQueue = DispatchQueue.main
    let backgroundQueue = DispatchQueue(label: "com.mytube.background", qos: .userInitiated)

    @Published var activeProfile: ProfileModel

    private let userDefaults: UserDefaults

    init(
        persistence: PersistenceController,
        storagePaths: StoragePaths,
        videoLibrary: VideoLibrary,
        remoteVideoStore: RemoteVideoStore,
        remoteVideoDownloader: RemoteVideoDownloader,
        profileStore: ProfileStore,
        thumbnailer: Thumbnailer,
        editRenderer: EditRenderer,
        parentAuth: ParentAuth,
        rankingEngine: RankingEngine,
        keyStore: KeychainKeyStore,
        identityManager: IdentityManager,
        parentProfileStore: ParentProfileStore,
        parentProfilePublisher: ParentProfilePublisher,
        childProfilePublisher: ChildProfilePublisher,
        childProfileStore: ChildProfileStore,
        cryptoService: CryptoEnvelopeService,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        syncCoordinator: SyncCoordinator,
        directMessageOutbox: DirectMessageOutbox,
        storageRouter: StorageRouter,
        videoSharePublisher: VideoSharePublisher,
        videoShareCoordinator: VideoShareCoordinator,
        relationshipStore: RelationshipStore,
        followCoordinator: FollowCoordinator,
        backendClient: BackendClient,
        storageConfigurationStore: StorageConfigurationStore,
        managedStorageClient: ManagedStorageClient,
        byoStorageClient: MinIOClient?,
        backendBaseURL: URL,
        activeProfile: ProfileModel,
        userDefaults: UserDefaults,
        onboardingState: OnboardingState,
        storageModeSelection: StorageModeSelection
    ) {
        self.persistence = persistence
        self.storagePaths = storagePaths
        self.videoLibrary = videoLibrary
        self.remoteVideoStore = remoteVideoStore
        self.remoteVideoDownloader = remoteVideoDownloader
        self.profileStore = profileStore
        self.thumbnailer = thumbnailer
        self.editRenderer = editRenderer
        self.parentAuth = parentAuth
        self.rankingEngine = rankingEngine
        self.keyStore = keyStore
        self.identityManager = identityManager
        self.parentProfileStore = parentProfileStore
        self.parentProfilePublisher = parentProfilePublisher
        self.childProfilePublisher = childProfilePublisher
        self.childProfileStore = childProfileStore
        self.cryptoService = cryptoService
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.syncCoordinator = syncCoordinator
        self.directMessageOutbox = directMessageOutbox
        self.storageRouter = storageRouter
        self.videoSharePublisher = videoSharePublisher
        self.videoShareCoordinator = videoShareCoordinator
        self.relationshipStore = relationshipStore
        self.followCoordinator = followCoordinator
        self.backendClient = backendClient
        self.storageConfigurationStore = storageConfigurationStore
        self.managedStorageClient = managedStorageClient
        self.byoStorageClient = byoStorageClient
        self.backendBaseURL = backendBaseURL
        self.activeProfile = activeProfile
        self.userDefaults = userDefaults
        self.onboardingState = onboardingState
        self.storageModeSelection = storageModeSelection

        relationshipStore.followRelationshipsPublisher
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.syncCoordinator.refreshSubscriptions() }
            }
            .store(in: &cancellables)
}

enum StorageModeError: Error {
    case configurationMissing
}

    static func live() -> AppEnvironment {
        let persistence = PersistenceController.shared
        let storagePaths: StoragePaths
        do {
            storagePaths = try StoragePaths()
        } catch {
            assertionFailure("Storage path initialization failed: \(error)")
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("MyTube", isDirectory: true)
            storagePaths = try! StoragePaths(baseURL: tempURL)
        }
        let videoLibrary = VideoLibrary(persistence: persistence, storagePaths: storagePaths)
        let remoteVideoStore = RemoteVideoStore(persistence: persistence)
        let profileStore = ProfileStore(persistence: persistence)
        let thumbnailer = Thumbnailer(storagePaths: storagePaths)
        let editRenderer = EditRenderer(storagePaths: storagePaths)
        let parentAuth = ParentAuth()
        let rankingEngine = RankingEngine()
        let keyStore = KeychainKeyStore()
        let identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)
        let parentProfileStore = ParentProfileStore(persistence: persistence)
        let childProfileStore = ChildProfileStore(persistence: persistence)
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = RelayPoolNostrClient()
        let defaults = UserDefaults.standard
        let relayDirectory = RelayDirectory(userDefaults: defaults)
        let relationshipStore = RelationshipStore(persistence: persistence)
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
        let syncCoordinator = SyncCoordinator(
            persistence: persistence,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            keyStore: keyStore,
            cryptoService: cryptoService,
            relationshipStore: relationshipStore,
            parentProfileStore: parentProfileStore,
            childProfileStore: childProfileStore
        )
        let directMessageOutbox = DirectMessageOutbox(
            keyStore: keyStore,
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        let legacyDefault = "http://127.0.0.1:8080"
        let managedDefault = "https://auth.tubestr.app"
        let storedBackendURL = defaults.string(forKey: "backend.baseURL")
        let resolvedBackendURLString: String
        if let storedBackendURL {
            if storedBackendURL == legacyDefault {
                resolvedBackendURLString = managedDefault
                defaults.set(resolvedBackendURLString, forKey: "backend.baseURL")
            } else {
                resolvedBackendURLString = storedBackendURL
            }
        } else {
            resolvedBackendURLString = managedDefault
            defaults.set(resolvedBackendURLString, forKey: "backend.baseURL")
        }
        let backendBaseURL = URL(string: resolvedBackendURLString)!
        let backendClient = BackendClient(baseURL: backendBaseURL, keyStore: keyStore)
        let storageConfigurationStore = StorageConfigurationStore(userDefaults: defaults)
        let managedStorageClient = ManagedStorageClient(backend: backendClient)

        var storageMode = storageConfigurationStore.currentMode()
        var byoStorageClient: MinIOClient?
        if storageMode == .byo {
            if let config = try? storageConfigurationStore.loadBYOConfig() {
                let minioConfig = MinIOConfiguration(
                    apiBaseURL: config.endpoint,
                    bucket: config.bucket,
                    accessKey: config.accessKey,
                    secretKey: config.secretKey,
                    region: config.region,
                    pathStyle: config.pathStyle
                )
                byoStorageClient = MinIOClient(configuration: minioConfig)
            } else {
                storageMode = .managed
            }
        }

        let initialStorageClient: any MediaStorageClient = {
            if storageMode == .byo, let byoStorageClient {
                return byoStorageClient
            } else {
                return managedStorageClient
            }
        }()

        let storageRouter = StorageRouter(initialClient: initialStorageClient)
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

        let activeProfile = (try? profileStore.fetchProfiles().first) ?? ProfileModel.placeholder()

        let onboardingState: OnboardingState = identityManager.hasParentIdentity() ? .ready : .needsParentIdentity

        let environment = AppEnvironment(
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
            storageRouter: storageRouter,
            videoSharePublisher: videoSharePublisher,
            videoShareCoordinator: videoShareCoordinator,
            relationshipStore: relationshipStore,
            followCoordinator: followCoordinator,
            backendClient: backendClient,
            storageConfigurationStore: storageConfigurationStore,
            managedStorageClient: managedStorageClient,
            byoStorageClient: byoStorageClient,
            backendBaseURL: backendBaseURL,
            activeProfile: activeProfile,
            userDefaults: defaults,
            onboardingState: onboardingState,
            storageModeSelection: storageMode
        )

        if onboardingState == .ready {
            Task {
                await syncCoordinator.start()
            }
        }

        return environment
    }

    func backendEndpointString() -> String {
        backendBaseURL.absoluteString
    }

    func updateBackendEndpoint(_ url: URL) {
        backendBaseURL = url
        userDefaults.set(url.absoluteString, forKey: "backend.baseURL")
        Task {
            await backendClient.updateBaseURL(url)
        }
        if storageModeSelection == .managed {
            Task {
                await storageRouter.updateClient(managedStorageClient)
            }
        }
    }

    func switchProfile(_ profile: ProfileModel) {
        activeProfile = profile
    }

    func completeOnboarding() {
        guard onboardingState != .ready else { return }
        onboardingState = .ready
        Task {
            await syncCoordinator.start()
        }
    }

    func applyStorageMode(_ mode: StorageModeSelection, config: UserStorageConfig? = nil) throws {
        switch mode {
        case .managed:
            try storageConfigurationStore.clearBYOConfig()
            storageConfigurationStore.setMode(.managed)
            storageModeSelection = .managed
            Task {
                await storageRouter.updateClient(managedStorageClient)
            }
        case .byo:
            guard let config else {
                throw StorageModeError.configurationMissing
            }
            try storageConfigurationStore.saveBYOConfig(config)
            storageConfigurationStore.setMode(.byo)
            let minioConfig = MinIOConfiguration(
                apiBaseURL: config.endpoint,
                bucket: config.bucket,
                accessKey: config.accessKey,
                secretKey: config.secretKey,
                region: config.region,
                pathStyle: config.pathStyle
            )
            let client = MinIOClient(configuration: minioConfig)
            byoStorageClient = client
            storageModeSelection = .byo
            Task {
                await storageRouter.updateClient(client)
            }
        }
    }

    func resetApp() async {
        await syncCoordinator.stop()

        do {
            try parentAuth.clearPin()
        } catch {
            assertionFailure("Failed to clear parent PIN: \(error)")
        }

        do {
            try keyStore.removeAll()
        } catch {
            assertionFailure("Failed to clear key store: \(error)")
        }

        do {
            try persistence.resetStores()
        } catch {
            assertionFailure("Failed to reset persistence: \(error)")
        }

        do {
            try storagePaths.clearAllContents()
        } catch {
            assertionFailure("Failed to clear storage directories: \(error)")
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            userDefaults.removePersistentDomain(forName: bundleID)
            userDefaults.synchronize()
        }

        await relayDirectory.resetToDefaults()

        activeProfile = (try? profileStore.fetchProfiles().first) ?? ProfileModel.placeholder()
        onboardingState = .needsParentIdentity
    }

    enum OnboardingState {
        case needsParentIdentity
        case ready
    }
}
