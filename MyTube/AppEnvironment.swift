//
//  AppEnvironment.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let persistence: PersistenceController
    let storagePaths: StoragePaths
    let videoLibrary: VideoLibrary
    let profileStore: ProfileStore
    let thumbnailer: Thumbnailer
    let editRenderer: EditRenderer
    let parentAuth: ParentAuth
    let rankingEngine: RankingEngine
    let keyStore: KeychainKeyStore
    let cryptoService: CryptoEnvelopeService
    let nostrClient: NostrClient
    let relayDirectory: RelayDirectory
    let syncCoordinator: SyncCoordinator

    @Published var calmModeEnabled: Bool

    let mainQueue = DispatchQueue.main
    let backgroundQueue = DispatchQueue(label: "com.mytube.background", qos: .userInitiated)

    @Published var activeProfile: ProfileModel

    private let userDefaults: UserDefaults

    init(
        persistence: PersistenceController,
        storagePaths: StoragePaths,
        videoLibrary: VideoLibrary,
        profileStore: ProfileStore,
        thumbnailer: Thumbnailer,
        editRenderer: EditRenderer,
        parentAuth: ParentAuth,
        rankingEngine: RankingEngine,
        keyStore: KeychainKeyStore,
        cryptoService: CryptoEnvelopeService,
        nostrClient: NostrClient,
        relayDirectory: RelayDirectory,
        syncCoordinator: SyncCoordinator,
        activeProfile: ProfileModel,
        calmModeEnabled: Bool,
        userDefaults: UserDefaults
    ) {
        self.persistence = persistence
        self.storagePaths = storagePaths
        self.videoLibrary = videoLibrary
        self.profileStore = profileStore
        self.thumbnailer = thumbnailer
        self.editRenderer = editRenderer
        self.parentAuth = parentAuth
        self.rankingEngine = rankingEngine
        self.keyStore = keyStore
        self.cryptoService = cryptoService
        self.nostrClient = nostrClient
        self.relayDirectory = relayDirectory
        self.syncCoordinator = syncCoordinator
        self.activeProfile = activeProfile
        self.calmModeEnabled = calmModeEnabled
        self.userDefaults = userDefaults
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
        let profileStore = ProfileStore(persistence: persistence)
        let thumbnailer = Thumbnailer(storagePaths: storagePaths)
        let editRenderer = EditRenderer(storagePaths: storagePaths)
        let parentAuth = ParentAuth()
        let rankingEngine = RankingEngine()
        let keyStore = KeychainKeyStore()
        let cryptoService = CryptoEnvelopeService()
        let nostrClient = URLSessionNostrClient()
        let defaults = UserDefaults.standard
        let relayDirectory = RelayDirectory(userDefaults: defaults)
        let syncCoordinator = SyncCoordinator(
            persistence: persistence,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )

        let activeProfile: ProfileModel
        if let existing = try? profileStore.fetchProfiles().first {
            activeProfile = existing
        } else {
            activeProfile = (try? profileStore.createProfile(
                name: "Sky",
                theme: .ocean,
                avatarAsset: "avatar.dolphin"
            )) ?? ProfileModel(
                id: UUID(),
                name: "Sky",
                theme: .ocean,
                avatarAsset: "avatar.dolphin"
            )
        }

        let environment = AppEnvironment(
            persistence: persistence,
            storagePaths: storagePaths,
            videoLibrary: videoLibrary,
            profileStore: profileStore,
            thumbnailer: thumbnailer,
            editRenderer: editRenderer,
            parentAuth: parentAuth,
            rankingEngine: rankingEngine,
            keyStore: keyStore,
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory,
            syncCoordinator: syncCoordinator,
            activeProfile: activeProfile,
            calmModeEnabled: defaults.bool(forKey: "calmModeEnabled"),
            userDefaults: defaults
        )

        Task {
            await syncCoordinator.start()
        }

        return environment
    }

    func switchProfile(_ profile: ProfileModel) {
        activeProfile = profile
    }

    func setCalmMode(enabled: Bool) {
        calmModeEnabled = enabled
        userDefaults.set(enabled, forKey: "calmModeEnabled")
    }
}
