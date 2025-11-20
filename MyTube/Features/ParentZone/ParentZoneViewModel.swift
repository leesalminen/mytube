//
//  ParentZoneViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Combine
import Foundation
import MDKBindings
import NostrSDK
import OSLog

struct MarmotDiagnostics: Equatable {
    let groupCount: Int
    let pendingWelcomes: Int

    static let empty = MarmotDiagnostics(groupCount: 0, pendingWelcomes: 0)
}

@MainActor
final class ParentZoneViewModel: ObservableObject {
    struct PendingWelcomeItem: Identifiable, Equatable {
        let welcome: Welcome

        var id: String { welcome.id }
        var groupName: String {
            let name = welcome.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "New Group" : name
        }
        var groupDescription: String? {
            let description = welcome.groupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? nil : description
        }
        var welcomerKey: String { welcome.welcomer }
        var relayList: [String] { welcome.groupRelays }
        var memberCount: Int { Int(welcome.memberCount) }
        var adminCount: Int { welcome.groupAdminPubkeys.count }

        var relaySummary: String? {
            guard !relayList.isEmpty else { return nil }
            if relayList.count <= 2 {
                return relayList.joined(separator: ", ")
            }
            let prefix = relayList.prefix(2).joined(separator: ", ")
            return "\(prefix) +\(relayList.count - 2) more"
        }
    }

    struct GroupSummary: Equatable {
        let id: String
        let name: String
        let description: String
        let state: String
        let memberCount: Int
        let adminCount: Int
        let relayCount: Int
        let lastMessageAt: Date?

        var displayName: String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Family Group" : trimmed
        }

        var isActive: Bool {
            state.lowercased() == "active"
        }
    }

    struct RemoteShareStats: Equatable {
        let availableCount: Int
        let revokedCount: Int
        let deletedCount: Int
        let blockedCount: Int
        let lastSharedAt: Date?

        var totalCount: Int {
            availableCount + revokedCount + deletedCount + blockedCount
        }

        var hasAvailableShares: Bool {
            availableCount > 0
        }
    }

    enum ShareFlowError: LocalizedError {
        case parentIdentityMissing
        case childProfileMissing
        case childKeyMissing(name: String)
        case noApprovedFamilies

        var errorDescription: String? {
            switch self {
            case .parentIdentityMissing:
                return "Generate or import the parent key before sending secure shares."
            case .childProfileMissing:
                return "Could not locate the child's profile for this video. Refresh Parent Zone and try again."
            case .childKeyMissing(let name):
                return "Create or import a key for \(name) before sending secure shares."
            case .noApprovedFamilies:
                return "Accept a Marmot invite from this family before sharing videos."
            }
        }
    }

    @Published var isUnlocked = false
    @Published var pinEntry = ""
    @Published var newPin = ""
    @Published var confirmPin = ""
    @Published var errorMessage: String?
    @Published var videos: [VideoModel] = []
    @Published var storageUsage: StorageUsage = .empty
    @Published var relayEndpoints: [RelayDirectory.Endpoint] = []
    @Published var newRelayURL: String = ""
    @Published var relayStatuses: [RelayHealth] = []
    @Published var parentIdentity: ParentIdentity?
    @Published var parentSecretVisible = false
    @Published var parentProfile: ParentProfileModel?
    @Published var childIdentities: [ChildIdentityItem] = []
    @Published var childSecretVisibility: Set<UUID> = []
    @Published private(set) var publishingChildIDs: Set<UUID> = []
    @Published var reports: [ReportModel] = []
    @Published var storageMode: StorageModeSelection = .managed
    @Published var entitlement: CloudEntitlement?
    @Published var isRefreshingEntitlement = false
    @Published var marmotDiagnostics: MarmotDiagnostics = .empty
    @Published var isRefreshingMarmotDiagnostics = false
    @Published var byoEndpoint: String = ""
    @Published var byoBucket: String = ""
    @Published var byoRegion: String = ""
    @Published var byoAccessKey: String = ""
    @Published var byoSecretKey: String = ""
    @Published var byoPathStyle: Bool = true
    @Published var backendEndpoint: String = ""
    @Published private(set) var pendingWelcomes: [PendingWelcomeItem] = []
    @Published var isRefreshingPendingWelcomes = false
    @Published private(set) var welcomeActionsInFlight: Set<String> = []
    @Published private(set) var groupSummaries: [String: GroupSummary] = [:]
    @Published private(set) var shareStatsByChild: [String: RemoteShareStats] = [:]
    @Published var requiresVideoApproval: Bool = false
    @Published var enableContentScanning: Bool = true
    @Published var pendingApprovalVideos: [VideoModel] = []

    private let environment: AppEnvironment
    private let parentAuth: ParentAuth
    private let parentKeyPackageStore: ParentKeyPackageStore
    private let welcomeClient: any WelcomeHandling
    private let parentalControlsStore: ParentalControlsStore
    private var delegationCache: [UUID: ChildDelegation] = [:]
    private var lastCreatedChildID: UUID?
    private var childKeyLookup: [String: ChildIdentityItem] = [:]
    private var pendingParentKeyPackages: [String: [String]]
    private var latestParentKeyPackage: String?
    private let eventSigner = NostrEventSigner()
    private var cancellables: Set<AnyCancellable> = []
    private var localParentKeyVariants: Set<String> = []
    private var marmotObservers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.mytube", category: "ParentZoneViewModel")
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    init(environment: AppEnvironment, welcomeClient: (any WelcomeHandling)? = nil) {
        self.environment = environment
        self.parentAuth = environment.parentAuth
        self.parentKeyPackageStore = environment.parentKeyPackageStore
        self.welcomeClient = welcomeClient ?? environment.mdkActor
        self.pendingParentKeyPackages = environment.parentKeyPackageStore.allPackages()
        self.storageMode = environment.storageModeSelection
        self.parentalControlsStore = environment.parentalControlsStore

        loadStoredBYOConfig()
        backendEndpoint = environment.backendEndpointString()

        // Relationship store removed - using MDK groups directly

        environment.reportStore.$reports
            .receive(on: RunLoop.main)
            .sink { [weak self] reports in
                self?.reports = reports.sorted { $0.createdAt > $1.createdAt }
            }
            .store(in: &cancellables)

        environment.$storageModeSelection
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self else { return }
                self.storageMode = mode
                if mode == .byo {
                    self.loadStoredBYOConfig()
                }
            }
            .store(in: &cancellables)

        observeMarmotNotifications()
        loadParentalControls()
    }

    deinit {
        for observer in marmotObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var needsSetup: Bool {
        !parentAuth.isPinConfigured()
    }

    func authenticate() {
        do {
            if parentAuth.isPinConfigured() {
                guard try parentAuth.validate(pin: pinEntry) else {
                    errorMessage = "Incorrect PIN"
                    return
                }
                unlock()
            } else {
                guard newPin == confirmPin, newPin.count >= 4 else {
                    errorMessage = "PINs must match and be 4+ digits"
                    return
                }
                try parentAuth.configure(pin: newPin)
                unlock()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithBiometrics() {
        Task {
            do {
                try await parentAuth.evaluateBiometric(reason: "Unlock Parent Zone")
                unlock()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func publishParentProfile(name: String?) async {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a parent name before publishing."
            return
        }

        do {
            let model = try await environment.parentProfilePublisher.publishProfile(
                name: trimmedName,
                displayName: trimmedName,
                about: nil,
                pictureURL: nil,
                nip05: nil
            )
            parentProfile = model
            if let identity = try environment.identityManager.parentIdentity() {
                parentIdentity = identity
                updateParentKeyCache(identity)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func publishChildProfile(childId: UUID) {
        guard let index = childIdentities.firstIndex(where: { $0.id == childId }) else {
            errorMessage = "Child profile not found."
            return
        }
        let item = childIdentities[index]
        guard let identity = item.identity else {
            errorMessage = "Generate a child key before publishing."
            return
        }

        publishingChildIDs.insert(childId)
        let profile = item.profile

        Task {
            do {
                let metadata = try await environment.childProfilePublisher.publishProfile(
                    for: profile,
                    identity: identity
                )
                await MainActor.run {
                    guard let currentIndex = self.childIdentities.firstIndex(where: { $0.id == childId }) else {
                        return
                    }
                    self.childIdentities[currentIndex] = self.childIdentities[currentIndex].updating(metadata: metadata)
                    if let identity = self.childIdentities[currentIndex].identity {
                        let hex = identity.keyPair.publicKeyHex.lowercased()
                        self.childKeyLookup[hex] = self.childIdentities[currentIndex]
                        if let bech32 = identity.publicKeyBech32?.lowercased() {
                            self.childKeyLookup[bech32] = self.childIdentities[currentIndex]
                        }
                    }
                    self.errorMessage = nil
                }
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self.errorMessage = description
                }
            }

            await MainActor.run {
                self.publishingChildIDs.remove(childId)
            }
        }
    }

    func refreshVideos() {
        do {
            videos = try environment.videoLibrary.fetchVideos(profileId: environment.activeProfile.id, includeHidden: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadParentalControls() {
        requiresVideoApproval = parentalControlsStore.requiresVideoApproval
        enableContentScanning = parentalControlsStore.enableContentScanning || parentalControlsStore.requiresVideoApproval
    }

    func updateApprovalRequirement(_ enabled: Bool) {
        parentalControlsStore.setRequiresVideoApproval(enabled)
        requiresVideoApproval = enabled
        if enabled {
            enableContentScanning = true
        }
        loadPendingApprovals()
    }

    func updateContentScanning(_ enabled: Bool) {
        guard !requiresVideoApproval else {
            enableContentScanning = true
            parentalControlsStore.setEnableContentScanning(true)
            return
        }
        enableContentScanning = enabled
        parentalControlsStore.setEnableContentScanning(enabled)
    }

    func loadPendingApprovals() {
        let request = VideoEntity.fetchRequest()
        request.predicate = NSPredicate(format: "approvalStatus == %@", VideoModel.ApprovalStatus.pending.rawValue)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \VideoEntity.createdAt, ascending: false)]
        do {
            let entities = try environment.persistence.viewContext.fetch(request)
            pendingApprovalVideos = entities.compactMap(VideoModel.init(entity:))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshPendingApprovals() {
        loadPendingApprovals()
    }

    func approvePendingVideo(_ videoId: UUID) {
        Task {
            do {
                try await environment.videoShareCoordinator.publishVideo(videoId)
                loadPendingApprovals()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func storageBreakdown() {
        let root = environment.storagePaths.rootURL
        let media = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.media.rawValue))
        let thumbs = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.thumbs.rawValue))
        let edits = totalSize(at: root.appendingPathComponent(StoragePaths.Directory.edits.rawValue))
        storageUsage = StorageUsage(media: media, thumbs: thumbs, edits: edits)
    }

    func refreshEntitlement(force: Bool = false) {
        guard storageMode == .managed else {
            entitlement = nil
            isRefreshingEntitlement = false
            errorMessage = nil
            return
        }
        isRefreshingEntitlement = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRefreshingEntitlement = false }
            do {
                self.logger.info("Requesting entitlement from \(self.environment.backendEndpointString(), privacy: .public)")
                let response = try await self.environment.backendClient.fetchEntitlement(forceRefresh: force)
                self.entitlement = CloudEntitlement(response: response)
                if self.storageMode == .managed {
                    self.errorMessage = nil
                }
            } catch {
                self.logger.error("Entitlement fetch failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func activateManagedStorage() {
        do {
            try environment.applyStorageMode(.managed)
            storageMode = .managed
            errorMessage = nil
            backendEndpoint = environment.backendEndpointString()
            entitlement = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateBYOStorage() {
        guard let config = buildBYOConfigFromInputs() else {
            return
        }
        do {
            try environment.applyStorageMode(.byo, config: config)
            storageMode = .byo
            errorMessage = nil
            loadStoredBYOConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadStoredBYOConfig() {
        guard let config = try? environment.storageConfigurationStore.loadBYOConfig() else {
            resetBYOFormFields()
            return
        }

        byoEndpoint = config.endpoint.absoluteString
        byoBucket = config.bucket
        byoRegion = config.region
        byoAccessKey = config.accessKey
        byoSecretKey = config.secretKey
        byoPathStyle = config.pathStyle
    }

    private func resetBYOFormFields() {
        byoEndpoint = ""
        byoBucket = ""
        byoRegion = ""
        byoAccessKey = ""
        byoSecretKey = ""
        byoPathStyle = true
    }

    private func buildBYOConfigFromInputs() -> UserStorageConfig? {
        let endpointString = byoEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointString.isEmpty else {
            errorMessage = "Enter the S3 endpoint URL."
            return nil
        }

        guard let endpointURL = URL(string: endpointString),
              let scheme = endpointURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            errorMessage = "Endpoint URL must start with https:// or http://."
            return nil
        }

        let bucket = byoBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            errorMessage = "Enter the bucket name."
            return nil
        }

        let regionValue = byoRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !regionValue.isEmpty else {
            errorMessage = "Enter the storage region."
            return nil
        }

        let accessKeyValue = byoAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKeyValue.isEmpty else {
            errorMessage = "Enter the access key."
            return nil
        }

        guard !byoSecretKey.isEmpty else {
            errorMessage = "Enter the secret key."
            return nil
        }

        return UserStorageConfig(
            endpoint: endpointURL,
            bucket: bucket,
            region: regionValue,
            accessKey: accessKeyValue,
            secretKey: byoSecretKey,
            pathStyle: byoPathStyle
        )
    }

    func applyBackendEndpoint() {
        let trimmed = backendEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter the backend base URL."
            return
        }

        guard storageMode == .managed else {
            errorMessage = "Switch to Managed storage before configuring the MyTube backend."
            return
        }

        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["https", "http"].contains(scheme),
            url.host != nil
        else {
            errorMessage = "Backend URL must include http(s) scheme and host."
            return
        }

        environment.updateBackendEndpoint(url)
        backendEndpoint = url.absoluteString
        entitlement = nil
        errorMessage = nil
    }

    func toggleVisibility(for video: VideoModel) {
        Task {
            do {
                let updated = try await environment.videoLibrary.toggleHidden(videoId: video.id, isHidden: !video.hidden)
                updateCache(with: updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(video: VideoModel) {
        Task {
            do {
                try await environment.videoLibrary.deleteVideo(videoId: video.id)
                videos.removeAll { $0.id == video.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            storageBreakdown()
        }
    }

    func shareURL(for video: VideoModel) -> URL {
        environment.videoLibrary.videoFileURL(for: video)
    }

    func canShareRemotely(video: VideoModel) -> Bool {
        guard parentIdentity != nil else { return false }
        guard let item = childIdentities.first(where: { $0.id == video.profileId }),
              item.identity != nil else {
            return false
        }
        return !approvedParentKeys(forChild: video.profileId).isEmpty
    }

    func shareVideoRemotely(video: VideoModel, recipientPublicKey: String) async throws -> VideoShareMessage {
        let parentIdentity: ParentIdentity
        do {
            parentIdentity = try ensureParentIdentityLoaded()
        } catch {
            throw ShareFlowError.parentIdentityMissing
        }

        if !childIdentities.contains(where: { $0.id == video.profileId }) {
            loadIdentities()
        }

        guard let childItem = childIdentities.first(where: { $0.id == video.profileId }) else {
            throw ShareFlowError.childProfileMissing
        }
        guard let identity = childItem.identity else {
            throw ShareFlowError.childKeyMissing(name: childItem.displayName)
        }

        guard let remoteParent = ParentIdentityKey(string: recipientPublicKey) else {
            throw VideoSharePublisherError.invalidRecipientKey
        }

        guard let follow = followRelationship(
            for: video.profileId,
            childIdentity: identity,
            remoteParent: remoteParent,
            localParentHex: parentIdentity.publicKeyHex
        ) else {
            throw ShareFlowError.noApprovedFamilies
        }

        guard let groupId = resolvedGroupId(for: follow) else {
            throw GroupMembershipWorkflowError.groupIdentifierMissing
        }

        let ownerChild = identity.publicKeyBech32 ?? identity.publicKeyHex
        let message = try await environment.videoSharePublisher.makeShareMessage(
            video: video,
            ownerChildNpub: ownerChild
        )
        _ = try await environment.marmotShareService.publishVideoShare(
            message: message,
            mlsGroupId: groupId
        )
        return message
    }

    func ensureRelayConnection(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        await environment.syncCoordinator.refreshRelays()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let statuses = await environment.syncCoordinator.relayStatuses()
            if statuses.contains(where: { $0.status == .connected }) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    private func unlock() {
        print("🔓 ParentZone unlocking...")
        isUnlocked = true
        pinEntry = ""
        newPin = ""
        confirmPin = ""
        errorMessage = nil
        refreshVideos()
        storageBreakdown()
        loadRelays()
        loadIdentities()
        loadRelationships()
        loadParentalControls()
        loadPendingApprovals()
        loadStoredBYOConfig()
        refreshEntitlement()
        refreshMarmotDiagnostics()
        refreshGroupSummaries()
        refreshRemoteShareStats()
        refreshParentKeyPackageIfNeeded()
        print("🔄 Starting async refresh tasks...")
        Task {
            await linkOrphanedGroups()
            await refreshPendingWelcomes()
            refreshPendingApprovals()
            await environment.syncCoordinator.refreshSubscriptions()
            print("✅ Async refresh tasks completed")
        }
    }
    
    private func linkOrphanedGroups() async {
        print("🔗 Checking for orphaned groups (groups not linked to child profiles)...")
        
        // Get all groups from MDK
        let groups: [Group]
        do {
            groups = try await environment.mdkActor.getGroups()
            print("   Found \(groups.count) group(s) in MDK")
        } catch {
            print("   ❌ Failed to fetch groups: \(error.localizedDescription)")
            return
        }
        
        // Get all child profiles
        await MainActor.run {
            loadIdentities()
        }
        
        for group in groups {
            print("   Checking group: \(group.name) (ID: \(group.mlsGroupId.prefix(16))...)")
            
            // Check if any child is already linked to this group
            let alreadyLinked = childIdentities.contains { $0.profile.mlsGroupId == group.mlsGroupId }
            if alreadyLinked {
                print("      ✅ Already linked to a child profile")
                continue
            }
            
            print("      ⚠️ Orphaned! Trying to link...")
            await tryLinkGroupToChildProfile(groupId: group.mlsGroupId, groupName: group.name)
        }
        
        print("✅ Orphaned group check completed")
    }

    private func refreshParentKeyPackageIfNeeded() {
        guard latestParentKeyPackage == nil else { return }
        Task {
            await generateParentKeyPackage()
        }
    }

    private func generateParentKeyPackage() async {
        do {
            let parentIdentity = try ensureParentIdentityLoaded()
            let relays = await environment.relayDirectory.currentRelayURLs()
            guard !relays.isEmpty else { return }
            let relayStrings = relays.map(\.absoluteString)
            let keyPackage = try await createParentKeyPackage(
                relays: relays,
                relayStrings: relayStrings,
                parentIdentity: parentIdentity
            )
            latestParentKeyPackage = keyPackage
        } catch {
            logger.error("Unable to refresh parent key package: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateCache(with video: VideoModel) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index] = video
        } else {
            videos.append(video)
        }
    }

    private func totalSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func loadRelays() {
        Task {
            async let endpointsTask = environment.relayDirectory.allEndpoints()
            async let statusesTask = environment.syncCoordinator.relayStatuses()
            let endpoints = await endpointsTask
            let statuses = await statusesTask
            await MainActor.run {
                self.relayEndpoints = endpoints
                self.relayStatuses = statuses
            }
        }
    }

    func setRelay(id: String, enabled: Bool) {
        guard let endpoint = relayEndpoints.first(where: { $0.id == id }), let url = endpoint.url else { return }

        Task {
            await environment.relayDirectory.setRelay(url, enabled: enabled)
            await environment.syncCoordinator.refreshRelays()
            async let endpointsTask = environment.relayDirectory.allEndpoints()
            async let statusesTask = environment.syncCoordinator.relayStatuses()
            let endpoints = await endpointsTask
            let statuses = await statusesTask
            await MainActor.run {
                self.relayEndpoints = endpoints
                self.relayStatuses = statuses
            }
        }
    }

    func removeRelay(id: String) {
        guard let endpoint = relayEndpoints.first(where: { $0.id == id }), let url = endpoint.url else { return }

        Task {
            await environment.relayDirectory.removeRelay(url)
            await environment.syncCoordinator.refreshRelays()
            async let endpointsTask = environment.relayDirectory.allEndpoints()
            async let statusesTask = environment.syncCoordinator.relayStatuses()
            let endpoints = await endpointsTask
            let statuses = await statusesTask
            await MainActor.run {
                self.relayEndpoints = endpoints
                self.relayStatuses = statuses
            }
        }
    }

    func addRelay() {
        let trimmed = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Please enter a valid wss:// relay URL."
            return
        }

        newRelayURL = ""
        Task {
            await environment.relayDirectory.addRelay(url)
            await environment.syncCoordinator.refreshRelays()
            async let endpointsTask = environment.relayDirectory.allEndpoints()
            async let statusesTask = environment.syncCoordinator.relayStatuses()
            let endpoints = await endpointsTask
            let statuses = await statusesTask
            await MainActor.run {
                self.relayEndpoints = endpoints
                self.relayStatuses = statuses
            }
        }
    }

    func loadIdentities() {
        do {
            parentIdentity = try environment.identityManager.parentIdentity()
            updateParentKeyCache(parentIdentity)
            let profiles = try environment.profileStore.fetchProfiles()
            childIdentities = profiles.map { profile in
                let identity = environment.identityManager.childIdentity(for: profile)
                let metadata: ChildProfileModel?
                if let identity {
                    do {
                        metadata = try environment.childProfileStore.profile(for: identity.publicKeyHex)
                    } catch {
                        metadata = nil
                    }
                } else {
                    metadata = nil
                }
                return ChildIdentityItem(
                    profile: profile,
                    identity: identity,
                    delegation: delegationCache[profile.id],
                    publishedMetadata: metadata
                )
            }
            childKeyLookup.removeAll()
            for item in childIdentities {
                if let identity = item.identity {
                    let hex = identity.keyPair.publicKeyHex.lowercased()
                    childKeyLookup[hex] = item
                    if let bech32 = identity.publicKeyBech32?.lowercased() {
                        childKeyLookup[bech32] = item
                    }
                }
            }
            let existingIDs = Set(childIdentities.map { $0.id })
            childSecretVisibility = childSecretVisibility.intersection(existingIDs)
            publishingChildIDs = publishingChildIDs.intersection(existingIDs)
            // Note: refreshSubscriptions is now called explicitly by callers when needed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshConnections() {
        Task {
            await environment.syncCoordinator.refreshSubscriptions()
        }
    }

    func groupSummary(for child: ChildIdentityItem) -> GroupSummary? {
        guard let groupId = child.profile.mlsGroupId else { return nil }
        return groupSummaries[groupId]
    }

    func totalAvailableRemoteShares() -> Int {
        shareStatsByChild.values.reduce(0) { $0 + $1.availableCount }
    }

    func inboundReports() -> [ReportModel] {
        reports.filter { !$0.isOutbound }
    }

    func outboundReports() -> [ReportModel] {
        reports.filter { $0.isOutbound }
    }

    func markReportReviewed(_ report: ReportModel) {
        Task {
            do {
                try await environment.reportStore.updateStatus(
                    reportId: report.id,
                    status: .acknowledged,
                    action: report.actionTaken,
                    lastActionAt: Date()
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func dismissReport(_ report: ReportModel) {
        Task {
            do {
                try await environment.reportStore.updateStatus(
                    reportId: report.id,
                    status: .dismissed,
                    action: report.actionTaken,
                    lastActionAt: Date()
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func followInvite(for child: ChildIdentityItem) -> FollowInvite? {
        guard
            let parentIdentity = parentIdentity ?? (try? ensureParentIdentityLoaded()),
            let childPublic = child.publicKey
        else {
            return nil
        }

        guard let keyPackage = latestParentKeyPackage else {
            return nil
        }

        return FollowInvite(
            version: 2,
            childName: child.profile.name,
            childPublicKey: childPublic,
            parentPublicKey: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex,
            parentKeyPackages: [keyPackage]
        )
    }

    func storePendingKeyPackages(from invite: FollowInvite) {
        guard
            let packages = invite.parentKeyPackages,
            !packages.isEmpty,
            let normalizedParent = ParentIdentityKey(string: invite.parentPublicKey)?.hex.lowercased()
        else {
            print("⚠️ storePendingKeyPackages: Missing packages or invalid parent key")
            return
        }
        
        // Check if we already have these exact packages stored to avoid duplicates
        if let existingPackages = pendingParentKeyPackages[normalizedParent],
           existingPackages == packages {
            // Already stored, skip
            return
        }
        
        print("📦 Storing \(packages.count) key package(s) for parent \(normalizedParent.prefix(16))...")
        for (i, pkg) in packages.enumerated() {
            print("   Package [\(i)] length: \(pkg.count) chars")
        }
        pendingParentKeyPackages[normalizedParent] = packages
        parentKeyPackageStore.save(packages: packages, forParentKey: normalizedParent)
        print("✅ Key packages stored")
    }

    func hasPendingKeyPackages(for parentKey: String) -> Bool {
        guard let normalized = ParentIdentityKey(string: parentKey)?.hex.lowercased() else {
            return false
        }
        guard let packages = pendingParentKeyPackages[normalized] else {
            return false
        }
        return !packages.isEmpty
    }

    @discardableResult
    private func inviteParentToGroup(
        child: ChildIdentityItem,
        identity: ChildIdentity,
        keyPackages: [String],
        normalizedParentKey: String
    ) async throws -> String {
        print("🏗️ inviteParentToGroup: Checking if group exists...")
        
        // Check if group already exists
        if let existingGroupId = identity.profile.mlsGroupId {
            print("✅ Group already exists: \(existingGroupId.prefix(16))...")
            print("📤 Adding \(keyPackages.count) member(s) to existing group...")
            let relayOverride = await environment.relayDirectory.currentRelayURLs()
            let request = GroupMembershipCoordinator.AddMembersRequest(
                mlsGroupId: existingGroupId,
                keyPackageEventsJson: keyPackages,
                relayOverride: relayOverride
            )
            print("🚀 Calling groupMembershipCoordinator.addMembers...")
            _ = try await environment.groupMembershipCoordinator.addMembers(request: request)
            print("✅ Members added successfully")
            
            // Refresh the specific group summary
            await refreshGroupSummariesAsync(mlsGroupId: existingGroupId)
            
            // Refresh subscriptions to include newly added members (this triggers notifications)
            await environment.syncCoordinator.refreshSubscriptions()
            
            pendingParentKeyPackages.removeValue(forKey: normalizedParentKey)
            parentKeyPackageStore.removePackages(forParentKey: normalizedParentKey)
            return existingGroupId
        }
        
        // Group doesn't exist - create it with both parents as members
        print("🏗️ Creating new group with remote parent as initial member...")
        let parentIdentity = try ensureParentIdentityLoaded()
        let relays = await environment.relayDirectory.currentRelayURLs()
        guard !relays.isEmpty else {
            throw GroupMembershipWorkflowError.relaysUnavailable
        }
        let relayStrings = relays.map(\.absoluteString)
        
        // Build group name with both parent names
        let groupName = await buildGroupName(
            localParentKey: parentIdentity.publicKeyHex,
            remoteParentKey: normalizedParentKey,
            childName: child.displayName
        )
        
        // Create group with remote parent as the initial member (creator is added automatically)
        let request = GroupMembershipCoordinator.CreateGroupRequest(
            creatorPublicKeyHex: parentIdentity.publicKeyHex,
            memberKeyPackageEventsJson: keyPackages,  // Remote parent as initial member
            name: groupName,
            description: "Secure sharing for \(child.displayName)",
            relays: relayStrings,
            adminPublicKeys: [parentIdentity.publicKeyHex],
            relayOverride: relays
        )
        print("🚀 Calling groupMembershipCoordinator.createGroup...")
        let response = try await environment.groupMembershipCoordinator.createGroup(request: request)
        let groupId = response.result.group.mlsGroupId
        print("✅ Group created: \(groupId.prefix(16))...")
        
        print("💾 Updating ProfileStore with groupId...")
        try environment.profileStore.updateGroupId(groupId, forProfileId: identity.profile.id)
        print("✅ ProfileStore updated")
        
        // Update UI on main thread FIRST, before triggering notifications
        print("🔄 Loading identities on MainActor...")
        await MainActor.run {
            loadIdentities()
        }
        print("✅ Identities loaded")
        
        // Refresh the specific group summary
        print("🔄 Refreshing group summary for \(groupId.prefix(16))...")
        await refreshGroupSummariesAsync(mlsGroupId: groupId)
        print("✅ Group summary refreshed")
        
        // Refresh subscriptions to include new group members (this triggers notifications)
        print("🔄 Refreshing subscriptions...")
        await environment.syncCoordinator.refreshSubscriptions()
        print("✅ Subscriptions refreshed")
        
        pendingParentKeyPackages.removeValue(forKey: normalizedParentKey)
        parentKeyPackageStore.removePackages(forParentKey: normalizedParentKey)
        print("🎉 inviteParentToGroup completed successfully")
        return groupId
    }


    func addChildProfile(name: String, theme: ThemeDescriptor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a name for the child profile."
            return
        }
        do {
            let identity = try environment.identityManager.createChildIdentity(
                name: trimmed,
                theme: theme,
                avatarAsset: theme.defaultAvatarAsset
            )
            loadIdentities()
            childSecretVisibility.insert(identity.profile.id)
            lastCreatedChildID = identity.profile.id
            // Don't create group yet - MLS requires at least 2 members
            // Group will be created when first follow is established
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generateChildKey(for profileId: UUID) {
        guard let item = childIdentities.first(where: { $0.id == profileId }) else { return }

        do {
            var identity = try environment.identityManager.ensureChildIdentity(for: item.profile)
            let delegation = try environment.identityManager.issueDelegation(
                to: identity,
                conditions: DelegationConditions.defaultChild()
            )
            identity.delegation = delegation
            delegationCache[profileId] = delegation
            loadIdentities()
            childSecretVisibility.insert(profileId)
            errorMessage = nil
            Task {
                do {
                    try await ensureChildGroup(for: identity, preferredName: item.profile.name)
                } catch {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRelaysOnConnectivityError(_ error: Error) {
        if let transportError = error as? MarmotTransport.TransportError {
            if case .relaysUnavailable = transportError {
                Task {
                    await environment.syncCoordinator.refreshRelays()
                }
            }
        }
    }

    func importChildProfile(name: String, secret: String, theme: ThemeDescriptor) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a name for the child profile."
            return
        }
        guard !trimmedSecret.isEmpty else {
            errorMessage = "Paste the child nsec before importing."
            return
        }

        do {
            var identity = try environment.identityManager.importChildIdentity(
                trimmedSecret,
                profileName: trimmedName,
                theme: theme,
                avatarAsset: theme.defaultAvatarAsset
            )
            let delegation = try environment.identityManager.issueDelegation(
                to: identity,
                conditions: DelegationConditions.defaultChild()
            )
            identity.delegation = delegation
            delegationCache[identity.profile.id] = delegation
            loadIdentities()
            childSecretVisibility.insert(identity.profile.id)
            lastCreatedChildID = identity.profile.id
            errorMessage = nil
            Task {
                do {
                    try await ensureChildGroup(for: identity, preferredName: trimmedName)
                } catch {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reissueDelegation(for profileId: UUID) {
        guard let item = childIdentities.first(where: { $0.id == profileId }),
              let identity = item.identity else {
            errorMessage = "Child key is missing; generate or import it first."
            return
        }

        do {
            let delegation = try environment.identityManager.issueDelegation(
                to: identity,
                conditions: DelegationConditions.defaultChild()
            )
            delegationCache[profileId] = delegation
            loadIdentities()
            childSecretVisibility.insert(profileId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleParentSecretVisibility() {
        parentSecretVisible.toggle()
    }

    func isChildSecretVisible(_ id: UUID) -> Bool {
        childSecretVisibility.contains(id)
    }

    func toggleChildSecretVisibility(_ id: UUID) {
        if childSecretVisibility.contains(id) {
            childSecretVisibility.remove(id)
        } else {
            childSecretVisibility.insert(id)
        }
    }

    func isPublishingChild(_ id: UUID) -> Bool {
        publishingChildIDs.contains(id)
    }

    func createParentIdentity() {
        do {
            let identity = try environment.identityManager.generateParentIdentity(requireBiometrics: false)
            parentIdentity = identity
            updateParentKeyCache(identity)
            parentSecretVisible = false
            errorMessage = nil
            Task {
                await environment.syncCoordinator.refreshSubscriptions()
            }
            refreshParentKeyPackageIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetApp() {
        Task {
            await environment.resetApp()
            await MainActor.run {
                self.isUnlocked = false
                self.pinEntry = ""
                self.newPin = ""
                self.confirmPin = ""
                self.errorMessage = nil
                self.videos = []
                self.storageUsage = .empty
                self.relayEndpoints = []
                self.relayStatuses = []
                self.parentIdentity = nil
                self.parentSecretVisible = false
                self.childIdentities = []
                self.childSecretVisibility.removeAll()
                self.delegationCache.removeAll()
                self.childKeyLookup.removeAll()
                self.localParentKeyVariants.removeAll()
                self.pendingWelcomes = []
                self.isRefreshingPendingWelcomes = false
                self.welcomeActionsInFlight.removeAll()
            }
            // Relationship store removed - MDK groups refreshed automatically
        }
    }

    func refreshRelays() {
        Task {
            await environment.syncCoordinator.refreshRelays()
            async let endpointsTask = environment.relayDirectory.allEndpoints()
            async let statusesTask = environment.syncCoordinator.relayStatuses()
            let endpoints = await endpointsTask
            let statuses = await statusesTask
            await MainActor.run {
                self.relayEndpoints = endpoints
                self.relayStatuses = statuses
            }
        }
    }

    func refreshMarmotDiagnostics() {
        Task { @MainActor in
            guard !isRefreshingMarmotDiagnostics else { return }
            isRefreshingMarmotDiagnostics = true
            defer { isRefreshingMarmotDiagnostics = false }
            let stats = await environment.mdkActor.stats()
            marmotDiagnostics = MarmotDiagnostics(
                groupCount: stats.groupCount,
                pendingWelcomes: stats.pendingWelcomeCount
            )
        }
    }

    func refreshPendingWelcomes() async {
        guard !isRefreshingPendingWelcomes else { return }
        isRefreshingPendingWelcomes = true
        defer { isRefreshingPendingWelcomes = false }
        do {
            print("🔍 Fetching pending welcomes from MDK...")
            let welcomes = try await welcomeClient.getPendingWelcomes()
            print("✅ Found \(welcomes.count) pending welcome(s)")
            for (i, welcome) in welcomes.enumerated() {
                print("   Welcome [\(i)]: \(welcome.groupName) (ID: \(welcome.id.prefix(16))...)")
            }
            pendingWelcomes = welcomes.map(PendingWelcomeItem.init)
            print("✅ Updated pendingWelcomes @Published property")
        } catch {
            print("❌ Failed to load pending welcomes: \(error.localizedDescription)")
            logger.error("Failed to load pending welcomes: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func acceptWelcome(_ welcome: PendingWelcomeItem, linkToChildId: UUID?) async {
        guard !welcomeActionsInFlight.contains(welcome.id) else { return }
        welcomeActionsInFlight.insert(welcome.id)
        defer { welcomeActionsInFlight.remove(welcome.id) }
        do {
            try await welcomeClient.acceptWelcome(welcome: welcome.welcome)
            pendingWelcomes.removeAll { $0.id == welcome.id }
            refreshMarmotDiagnostics()
            notifyPendingWelcomeChange()
            notifyMarmotStateChange()
            await handleAcceptedWelcome(welcome.welcome, linkToChildId: linkToChildId)
        } catch {
            logger.error("Failed to accept welcome: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func declineWelcome(_ welcome: PendingWelcomeItem) async {
        guard !welcomeActionsInFlight.contains(welcome.id) else { return }
        welcomeActionsInFlight.insert(welcome.id)
        defer { welcomeActionsInFlight.remove(welcome.id) }
        do {
            try await welcomeClient.declineWelcome(welcome: welcome.welcome)
            pendingWelcomes.removeAll { $0.id == welcome.id }
            refreshMarmotDiagnostics()
            notifyPendingWelcomeChange()
            notifyMarmotStateChange()
        } catch {
            logger.error("Failed to decline welcome: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func isProcessingWelcome(_ welcome: PendingWelcomeItem) -> Bool {
        welcomeActionsInFlight.contains(welcome.id)
    }

    private func handleAcceptedWelcome(_ welcome: Welcome, linkToChildId: UUID?) async {
        print("🎉 handleAcceptedWelcome called for group: \(welcome.mlsGroupId.prefix(16))...")
        print("   Group name: \(welcome.groupName)")
        
        // Link to specified child, or try auto-matching by name
        if let childId = linkToChildId {
            print("   🔗 Linking to explicitly selected child: \(childId)")
            do {
                try environment.profileStore.updateGroupId(welcome.mlsGroupId, forProfileId: childId)
                print("   ✅ Linked group to child profile")
            } catch {
                print("   ❌ Failed to link: \(error.localizedDescription)")
            }
        } else {
            print("   🔍 No child specified, trying auto-match by name...")
            await tryLinkGroupToChildProfile(groupId: welcome.mlsGroupId, groupName: welcome.groupName)
        }
        
        // Refresh subscriptions to include new group members
        await environment.syncCoordinator.refreshSubscriptions()
        
        // Reload identities to update profile associations
        await MainActor.run {
            loadIdentities()
        }
        
        // Explicitly refresh group summaries for the new group
        refreshGroupSummaries(mlsGroupId: welcome.mlsGroupId)
    }
    
    private func buildGroupName(
        localParentKey: String,
        remoteParentKey: String?,
        childName: String
    ) async -> String {
        // Get local parent's name
        let localParentName: String
        if let localProfile = try? environment.parentProfileStore.profile(for: localParentKey),
           let name = localProfile.displayName ?? localProfile.name {
            localParentName = name
        } else {
            localParentName = "Me"
        }
        
        // Get remote parent's name if available
        if let remoteKey = remoteParentKey,
           let remoteProfile = try? environment.parentProfileStore.profile(for: remoteKey),
           let remoteName = remoteProfile.displayName ?? remoteProfile.name {
            // Both names available
            return "\(localParentName) & \(remoteName)'s Family"
        } else if remoteParentKey != nil {
            // Remote parent exists but no published name
            return "\(localParentName) & Friend's Family"
        } else {
            // No remote parent yet (solo group)
            return "\(localParentName)'s \(childName)"
        }
    }
    
    private func tryLinkGroupToChildProfile(groupId: String, groupName: String) async {
        print("🔗 Trying to link group \(groupId.prefix(16))... to child profile...")
        print("   Group name: '\(groupName)'")
        
        // Strategy 1: Try to match by group name pattern "{ChildName} Family"
        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.hasSuffix(" Family") {
            let childName = String(trimmedName.dropLast(" Family".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("   Extracted child name: '\(childName)'")
            
            // Find matching child by name
            if let matchingChild = childIdentities.first(where: { $0.profile.name.caseInsensitiveCompare(childName) == .orderedSame }) {
                print("   ✅ Found exact name match: \(matchingChild.displayName)")
                
                // Check if this child already has a group assigned
                if matchingChild.profile.mlsGroupId != nil {
                    print("   ⚠️ Child already has group ID: \(matchingChild.profile.mlsGroupId!.prefix(16))...")
                    return
                }
                
                // Update the ProfileStore to link this child to the group
                do {
                    try environment.profileStore.updateGroupId(groupId, forProfileId: matchingChild.id)
                    print("   ✅ Linked child '\(matchingChild.displayName)' to group \(groupId.prefix(16))...")
                    await MainActor.run {
                        loadIdentities()
                    }
                    return
                } catch {
                    print("   ❌ Failed to update ProfileStore: \(error.localizedDescription)")
                }
            }
        }
        
        // Strategy 2: If no name match, link to first child without a group
        print("   🔍 No name match, looking for first unlinked child...")
        if let unlinkedChild = childIdentities.first(where: { $0.profile.mlsGroupId == nil }) {
            print("   ✅ Found unlinked child: \(unlinkedChild.displayName)")
            do {
                try environment.profileStore.updateGroupId(groupId, forProfileId: unlinkedChild.id)
                print("   ✅ Auto-linked child '\(unlinkedChild.displayName)' to group \(groupId.prefix(16))...")
                await MainActor.run {
                    loadIdentities()
                }
            } catch {
                print("   ❌ Failed to update ProfileStore: \(error.localizedDescription)")
            }
        } else {
            print("   ⚠️ All children already have groups assigned")
            print("   Available children: \(childIdentities.map { "\($0.profile.name) (group: \($0.profile.mlsGroupId?.prefix(8) ?? "none"))" })")
        }
    }

    private func observeMarmotNotifications() {
        let center = NotificationCenter.default
        let pendingObserver = center.addObserver(
            forName: .marmotPendingWelcomesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePendingWelcomeNotification()
            }
        }
        let stateObserver = center.addObserver(
            forName: .marmotStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMarmotStateNotification()
            }
        }
        let messageObserver = center.addObserver(
            forName: .marmotMessagesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleMarmotMessagesNotification(notification)
            }
        }
        marmotObservers.append(contentsOf: [pendingObserver, stateObserver, messageObserver])
    }

    private func handlePendingWelcomeNotification() {
        print("🔔 handlePendingWelcomeNotification called, isUnlocked=\(isUnlocked)")
        // Always refresh - don't wait for user to unlock or visit the tab
        Task { [weak self] in
            await self?.refreshPendingWelcomes()
        }
        refreshMarmotDiagnostics()
    }

    private func handleMarmotStateNotification() {
        print("🔔 handleMarmotStateNotification called, isUnlocked=\(isUnlocked)")
        // Always refresh state, even if not unlocked - keeps internal state current
        refreshMarmotDiagnostics()
        Task { [weak self] in
            await self?.refreshMembershipSurfaces()
            // Also refresh pending welcomes since state change might mean new welcomes
            await self?.refreshPendingWelcomes()
        }
        refreshGroupSummaries()
        refreshRemoteShareStats()
    }

    private func handleMarmotMessagesNotification(_ notification: Notification) {
        refreshRemoteShareStats()
        if let groupId = notification.userInfo?["mlsGroupId"] as? String {
            refreshGroupSummaries(mlsGroupId: groupId)
        } else {
            refreshGroupSummaries()
        }
    }

    @MainActor
    private func refreshMembershipSurfaces() {
        loadIdentities()
        loadRelationships()
    }

    private func refreshGroupSummaries(mlsGroupId: String? = nil) {
        Task { [weak self] in
            await self?.refreshGroupSummariesAsync(mlsGroupId: mlsGroupId)
        }
    }
    
    private func refreshGroupSummariesAsync(mlsGroupId: String? = nil) async {
        print("📊 refreshGroupSummariesAsync called for: \(mlsGroupId?.prefix(16) ?? "all groups")...")
        do {
            if let groupId = mlsGroupId {
                print("   🔍 Fetching group from MDK...")
                guard let group = try await self.environment.mdkActor.getGroup(mlsGroupId: groupId) else {
                    print("   ⚠️ Group not found, removing from summaries")
                    await MainActor.run {
                        self.groupSummaries.removeValue(forKey: groupId)
                    }
                    return
                }
                print("   ✅ Group fetched: \(group.name)")
                print("   🔍 Building summary...")
                if let summary = await self.buildGroupSummary(group) {
                    print("   ✅ Summary built with \(summary.memberCount) members")
                    print("   💾 Updating @Published groupSummaries on MainActor...")
                    await MainActor.run {
                        self.groupSummaries[groupId] = summary
                        print("   ✅ @Published groupSummaries updated!")
                    }
                }
            } else {
                print("   🔍 Fetching all groups from MDK...")
                let groups = try await self.environment.mdkActor.getGroups()
                print("   ✅ Found \(groups.count) group(s)")
                var summaries: [String: GroupSummary] = [:]
                for group in groups {
                    if let summary = await self.buildGroupSummary(group) {
                        summaries[group.mlsGroupId] = summary
                    }
                }
                print("   💾 Updating @Published groupSummaries on MainActor...")
                await MainActor.run {
                    self.groupSummaries = summaries
                    print("   ✅ @Published groupSummaries updated!")
                }
            }
        } catch {
            print("   ❌ Error: \(error.localizedDescription)")
            self.logger.error("Failed to refresh Marmot groups: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func buildGroupSummary(_ group: Group) async -> GroupSummary? {
        do {
            async let relaysTask = environment.mdkActor.getRelays(inGroup: group.mlsGroupId)
            async let membersTask = environment.mdkActor.getMembers(inGroup: group.mlsGroupId)
            let relays = try await relaysTask
            let members = try await membersTask
            let lastMessage: Date?
            if let timestamp = group.lastMessageAt {
                lastMessage = Date(timeIntervalSince1970: TimeInterval(timestamp))
            } else {
                lastMessage = nil
            }
            return GroupSummary(
                id: group.mlsGroupId,
                name: group.name,
                description: group.description,
                state: group.state,
                memberCount: members.count,
                adminCount: group.adminPubkeys.count,
                relayCount: relays.count,
                lastMessageAt: lastMessage
            )
        } catch {
            logger.error("Failed to build Marmot group summary: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func refreshRemoteShareStats() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let summaries = try self.environment.remoteVideoStore.shareSummaries()
                var mapping: [String: RemoteShareStats] = [:]
                for summary in summaries {
                    let canonical = self.canonicalChildKey(summary.ownerChild) ?? summary.ownerChild.lowercased()
                    mapping[canonical] = RemoteShareStats(
                        availableCount: summary.availableCount,
                        revokedCount: summary.revokedCount,
                        deletedCount: summary.deletedCount,
                        blockedCount: summary.blockedCount,
                        lastSharedAt: summary.lastSharedAt
                    )
                }
                await MainActor.run {
                    self.shareStatsByChild = mapping
                }
            } catch {
                self.logger.error("Failed to refresh remote share stats: \(error.localizedDescription, privacy: .public)")
            }
        }
    }


    private func notifyPendingWelcomeChange() {
        NotificationCenter.default.post(name: .marmotPendingWelcomesDidChange, object: nil)
    }

    private func notifyMarmotStateChange() {
        NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
    }

    func status(for endpoint: RelayDirectory.Endpoint) -> RelayHealth? {
        relayStatuses.first {
            $0.url.absoluteString.caseInsensitiveCompare(endpoint.urlString) == .orderedSame
        }
    }

    private func updateParentKeyCache(_ identity: ParentIdentity?) {
        guard let identity else {
            localParentKeyVariants.removeAll()
            parentProfile = nil
            return
        }

        var variants: Set<String> = []
        variants.insert(identity.publicKeyHex.lowercased())
        if let bech32 = identity.publicKeyBech32?.lowercased() {
            variants.insert(bech32)
        }
        for variant in normalizedKeyVariants(identity.publicKeyHex) {
            variants.insert(variant.lowercased())
        }
        localParentKeyVariants = variants

        parentProfile = try? environment.parentProfileStore.profile(for: identity.publicKeyHex.lowercased())
    }

    private func childItem(forKey key: String) -> ChildIdentityItem? {
        for variant in normalizedKeyVariants(key) {
            if let item = childKeyLookup[variant] {
                return item
            }
        }
        return nil
    }


    func isValidParentKey(_ key: String) -> Bool {
        ParentIdentityKey(string: key) != nil
    }

    private func ensureChildGroup(for identity: ChildIdentity, preferredName: String) async throws {
        guard identity.profile.mlsGroupId == nil else { return }

        let parentIdentity = try ensureParentIdentityLoaded()
        let relays = await environment.relayDirectory.currentRelayURLs()
        guard !relays.isEmpty else {
            throw GroupMembershipWorkflowError.relaysUnavailable
        }
        let relayStrings = relays.map(\.absoluteString)

        let keyPackage = try await createParentKeyPackage(
            relays: relays,
            relayStrings: relayStrings,
            parentIdentity: parentIdentity
        )
        latestParentKeyPackage = keyPackage

        // Creator is automatically added to the group, don't include in member list
        // Build simple group name for solo groups (no remote parent yet)
        let groupName = await buildGroupName(
            localParentKey: parentIdentity.publicKeyHex,
            remoteParentKey: nil,
            childName: preferredName
        )
        
        let request = GroupMembershipCoordinator.CreateGroupRequest(
            creatorPublicKeyHex: parentIdentity.publicKeyHex,
            memberKeyPackageEventsJson: [],  // Empty - creator joins automatically
            name: groupName,
            description: "Secure sharing for \(preferredName)",
            relays: relayStrings,
            adminPublicKeys: [parentIdentity.publicKeyHex],
            relayOverride: relays
        )
        let response = try await environment.groupMembershipCoordinator.createGroup(request: request)
        let groupId = response.result.group.mlsGroupId
        try environment.profileStore.updateGroupId(groupId, forProfileId: identity.profile.id)
        
        // Update UI on main thread
        await MainActor.run {
            loadIdentities()
        }
        
        // Refresh the specific group summary
        await refreshGroupSummariesAsync(mlsGroupId: groupId)
        
        // Refresh subscriptions to include the new group
        await environment.syncCoordinator.refreshSubscriptions()
    }

    private func createParentKeyPackage(
        relays: [URL],
        relayStrings: [String],
        parentIdentity: ParentIdentity
    ) async throws -> String {
        let result = try await environment.mdkActor.createKeyPackage(
            forPublicKey: parentIdentity.publicKeyHex,
            relays: relayStrings
        )
        let eventJson = try encodeKeyPackageEvent(
            result: result,
            parentIdentity: parentIdentity
        )
        try await environment.marmotTransport.publish(
            jsonEvent: eventJson,
            relayOverride: relays
        )
        return eventJson
    }

    @discardableResult
    private func ensureParentIdentityLoaded() throws -> ParentIdentity {
        if let identity = parentIdentity {
            return identity
        }
        guard let identity = try environment.identityManager.parentIdentity() else {
            throw ShareFlowError.parentIdentityMissing
        }
        parentIdentity = identity
        updateParentKeyCache(identity)
        return identity
    }

    private func encodeKeyPackageEvent(
        result: KeyPackageResult,
        parentIdentity: ParentIdentity
    ) throws -> String {
        let tags = try result.tags.map { raw -> Tag in
            try Tag.parse(data: raw)
        }
        let event = try eventSigner.makeEvent(
            kind: MarmotEventKind.keyPackage.nostrKind,
            tags: tags,
            content: result.keyPackage,
            keyPair: parentIdentity.keyPair
        )
        return try event.asJson()
    }

    private func normalizedKeyVariants(_ key: String) -> [String] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants: Set<String> = [trimmed.lowercased()]
        if let data = Data(hexString: trimmed) {
            variants.insert(data.hexEncodedString().lowercased())
            if let bech = try? NIP19.encodePublicKey(data) {
                variants.insert(bech.lowercased())
            }
        } else if trimmed.lowercased().hasPrefix(NIP19Kind.npub.rawValue),
                  let decoded = try? NIP19.decode(trimmed.lowercased()),
                  decoded.kind == .npub {
            let hex = decoded.data.hexEncodedString().lowercased()
            variants.insert(hex)
            if let bech = try? NIP19.encodePublicKey(decoded.data) {
                variants.insert(bech.lowercased())
            }
        }
        return Array(variants)
    }

    private func canonicalChildKey(_ value: String) -> String? {
        ParentIdentityKey(string: value)?.hex.lowercased()
    }

    struct CloudEntitlement: Equatable {
        let plan: String
        let status: String
        let expiresAt: Date?
        let quotaBytes: Int64?
        let usedBytes: Int64?

        init(response: EntitlementResponse) {
            self.plan = response.plan
            self.status = response.status
            self.expiresAt = response.expiresAt
            self.quotaBytes = CloudEntitlement.parseBytes(response.quotaBytes)
            self.usedBytes = CloudEntitlement.parseBytes(response.usedBytes)
        }

        var statusLabel: String {
            status
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }

        var isActive: Bool {
            status.caseInsensitiveCompare("active") == .orderedSame
        }

        var usageSummary: String? {
            guard let quotaBytes else { return nil }
            let used = max(usedBytes ?? 0, 0)
            let quotaDescription = ParentZoneViewModel.byteFormatter.string(fromByteCount: quotaBytes)
            let usedDescription = ParentZoneViewModel.byteFormatter.string(fromByteCount: used)
            return "\(usedDescription) of \(quotaDescription) used"
        }

        var quotaDescription: String? {
            guard let quotaBytes else { return nil }
            return ParentZoneViewModel.byteFormatter.string(fromByteCount: quotaBytes)
        }

        var usageFraction: Double? {
            guard let quota = quotaBytes,
                  quota > 0,
                  let used = usedBytes else { return nil }
            return min(max(Double(used) / Double(quota), 0), 1)
        }

        private static func parseBytes(_ value: String?) -> Int64? {
            guard let value else { return nil }
            return Int64(value)
        }
    }

    struct StorageUsage {
        let media: Int64
        let thumbs: Int64
        let edits: Int64

        static let empty = StorageUsage(media: 0, thumbs: 0, edits: 0)

        var total: Int64 { media + thumbs + edits }
    }

    struct ChildIdentityItem: Identifiable {
        let profile: ProfileModel
        let identity: ChildIdentity?
        let delegation: ChildDelegation?
        let publishedMetadata: ChildProfileModel?

        var id: UUID { profile.id }
        var displayName: String { profile.name }
        var publicKey: String? {
            identity?.publicKeyBech32 ?? identity?.keyPair.publicKeyHex
        }
        var secretKey: String? {
            identity?.secretKeyBech32 ?? identity?.keyPair.privateKeyData.hexEncodedString()
        }

        var publishedName: String? {
            publishedMetadata?.bestName
        }

        var metadataUpdatedAt: Date? {
            publishedMetadata?.updatedAt
        }

        var delegationTag: String? {
            guard let tag = delegation?.nostrTag else { return nil }
            let components = [tag.name, tag.value] + tag.otherParameters
            return "[\(components.joined(separator: ", "))]"
        }

        func updating(metadata: ChildProfileModel?) -> ChildIdentityItem {
            ChildIdentityItem(
                profile: profile,
                identity: identity,
                delegation: delegation,
                publishedMetadata: metadata
            )
        }
    }

    struct FollowInvite: Codable, Sendable, Equatable {
        let version: Int
        let childName: String?
        let childPublicKey: String
        let parentPublicKey: String
        let parentKeyPackages: [String]?

        var encodedURL: String? {
            guard let data = try? JSONEncoder().encode(self) else {
                return nil
            }
            let base = data.base64EncodedString()
            var components = URLComponents()
            components.scheme = "tubestr"
            components.host = "follow-invite"
            components.queryItems = [
                URLQueryItem(name: "v", value: "\(version)"),
                URLQueryItem(name: "data", value: base)
            ]
            return components.url?.absoluteString
        }

        var shareText: String {
            let nameDescriptor = childName.map { " for \($0)" } ?? ""
            return """
            Tubestr Family Invite\(nameDescriptor)
            
            Open this link to connect:
            \(encodedURL ?? "")
            """
        }

        var shareItems: [Any] {
            var items: [Any] = []
            if let urlString = encodedURL, let url = URL(string: urlString) {
                items.append(url)
            }
            items.append(shareText)
            return items
        }

        static func decode(from string: String) -> FollowInvite? {
            if let invite = decodeURLString(string) {
                return invite
            }
            return nil
        }

        private static func decodeURLString(_ string: String) -> FollowInvite? {
            guard let url = URL(string: string),
                  url.scheme?.caseInsensitiveCompare("tubestr") == .orderedSame,
                  url.host?.caseInsensitiveCompare("follow-invite") == .orderedSame,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
                  let decodedData = Data(base64Encoded: dataParam)
            else { return nil }
            return try? JSONDecoder().decode(FollowInvite.self, from: decodedData)
        }
    }
}
