//
//  ParentZoneViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Combine
import Foundation
import OSLog

@MainActor
final class ParentZoneViewModel: ObservableObject {
    enum ShareFlowError: LocalizedError {
        case parentIdentityMissing
        case childProfileMissing
        case childKeyMissing(name: String)
        case noApprovedFollowers

        var errorDescription: String? {
            switch self {
            case .parentIdentityMissing:
                return "Generate or import the parent key before sending secure shares."
            case .childProfileMissing:
                return "Could not locate the child's profile for this video. Refresh Parent Zone and try again."
            case .childKeyMissing(let name):
                return "Create or import a key for \(name) before sending secure shares."
            case .noApprovedFollowers:
                return "Approve a follow from this parent before sharing videos."
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
    @Published var followRelationships: [FollowModel] = []
    @Published var reports: [ReportModel] = []
    @Published var storageMode: StorageModeSelection = .managed
    @Published var entitlement: CloudEntitlement?
    @Published var isRefreshingEntitlement = false
    @Published var byoEndpoint: String = ""
    @Published var byoBucket: String = ""
    @Published var byoRegion: String = ""
    @Published var byoAccessKey: String = ""
    @Published var byoSecretKey: String = ""
    @Published var byoPathStyle: Bool = true
    @Published var backendEndpoint: String = ""

    private let environment: AppEnvironment
    private let parentAuth: ParentAuth
    private var delegationCache: [UUID: ChildDelegation] = [:]
    private var lastCreatedChildID: UUID?
    private var childKeyLookup: [String: ChildIdentityItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var localParentKeyVariants: Set<String> = []
    private let logger = Logger(subsystem: "com.mytube", category: "ParentZoneViewModel")
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    init(environment: AppEnvironment) {
        self.environment = environment
        self.parentAuth = environment.parentAuth
        self.storageMode = environment.storageModeSelection

        loadStoredBYOConfig()
        backendEndpoint = environment.backendEndpointString()

        environment.relationshipStore.followRelationshipsPublisher
            .map { follows in
                follows.sorted { $0.updatedAt > $1.updatedAt }
            }
            .sink { [weak self] follows in
                self?.followRelationships = follows
            }
            .store(in: &cancellables)

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

        guard ParentIdentityKey(string: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex) != nil else {
            throw ShareFlowError.parentIdentityMissing
        }
        guard ParentIdentityKey(string: recipientPublicKey) != nil else {
            throw VideoSharePublisherError.invalidRecipientKey
        }

        guard let childItem = childIdentities.first(where: { $0.id == video.profileId }) else {
            throw ShareFlowError.childProfileMissing
        }
        guard let identity = childItem.identity else {
            throw ShareFlowError.childKeyMissing(name: childItem.displayName)
        }

        guard isApprovedParent(recipientPublicKey, forChild: video.profileId) else {
            throw ShareFlowError.noApprovedFollowers
        }

        let ownerChild = identity.publicKeyBech32 ?? identity.publicKeyHex
        return try await environment.videoSharePublisher.share(
            video: video,
            ownerChildNpub: ownerChild,
            recipientPublicKey: recipientPublicKey
        )
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
        loadStoredBYOConfig()
        refreshEntitlement()
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
            childIdentities = try profiles.map { profile in
                let identity = try environment.identityManager.childIdentity(for: profile)
                let metadata: ChildProfileModel?
                if let identity {
                    metadata = try environment.childProfileStore.profile(for: identity.publicKeyHex)
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
            Task {
                await environment.syncCoordinator.refreshSubscriptions()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadRelationships() {
        environment.relationshipStore.refreshAll()
    }

    func refreshConnections() {
        Task {
            await environment.syncCoordinator.refreshSubscriptions()
            await MainActor.run {
                self.environment.relationshipStore.refreshAll()
            }
        }
    }

    func incomingFollowRequests() -> [FollowModel] {
        followRelationships.filter { follow in
            guard targetProfile(for: follow) != nil else { return false }
            return !follow.approvedTo && follow.status != .revoked && follow.status != .blocked
        }
    }

    func outgoingFollowRequests() -> [FollowModel] {
        followRelationships.filter { follow in
            guard followerProfile(for: follow) != nil else { return false }
            return follow.approvedFrom && !follow.approvedTo && follow.status != .revoked && follow.status != .blocked
        }
    }

    func activeFollowConnections() -> [FollowModel] {
        followRelationships.filter { follow in
            guard follow.isFullyApproved else { return false }
            return followerProfile(for: follow) != nil || targetProfile(for: follow) != nil
        }
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

    func unblockFamily(for follow: FollowModel) {
        Task {
            guard let remoteKey = remoteParentKey(for: follow) else {
                await MainActor.run {
                    self.errorMessage = "Could not determine remote parent key to unblock."
                }
                return
            }

            do {
                _ = try await environment.followCoordinator.revokeFollow(
                    follow: follow,
                    remoteParentKey: remoteKey,
                    now: Date()
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func approvedParentKeys(forChild childId: UUID) -> [String] {
        guard let parentIdentity else { return [] }
        let localParentHex = parentIdentity.publicKeyHex.lowercased()
        let localVariants = localParentKeyVariants

        guard let childItem = childIdentities.first(where: { $0.id == childId }),
              let childIdentity = childItem.identity else {
            return []
        }

        let childVariants = Set(normalizedKeyVariants(childIdentity.publicKeyHex))
        var keys: Set<String> = []

        for follow in followRelationships where follow.isFullyApproved {
            let followerVariants = Set(normalizedKeyVariants(follow.followerChild))
            let targetVariants = Set(normalizedKeyVariants(follow.targetChild))

            guard !childVariants.isDisjoint(with: followerVariants) || !childVariants.isDisjoint(with: targetVariants) else {
                continue
            }

            var remoteParents = follow.remoteParentKeys(localParentHex: localParentHex)
            if remoteParents.isEmpty, let fallback = ParentIdentityKey(string: follow.lastMessage?.by ?? "")?.hex.lowercased() {
                remoteParents = [fallback]
            }

            for key in remoteParents where !key.isEmpty {
                let lower = key.lowercased()
                guard !localVariants.contains(lower) else { continue }
                keys.insert(lower)
            }
        }

        return keys.sorted()
    }

    func isApprovedParent(_ key: String, forChild childId: UUID) -> Bool {
        guard let scanned = ParentIdentityKey(string: key) else { return false }
        return approvedParentKeys(forChild: childId).contains {
            $0.caseInsensitiveCompare(scanned.hex) == .orderedSame
        }
    }

    func followerProfile(for follow: FollowModel) -> ChildIdentityItem? {
        childItem(forKey: follow.followerChild)
    }

    func targetProfile(for follow: FollowModel) -> ChildIdentityItem? {
        childItem(forKey: follow.targetChild)
    }

    func remoteParentKey(for follow: FollowModel) -> String? {
        guard let parentIdentity,
              let remoteHex = follow.remoteParentKeys(localParentHex: parentIdentity.publicKeyHex).first else {
            guard let fallback = follow.lastMessage?.by else { return nil }
            return localParentKeyVariants.contains(fallback.lowercased()) ? nil : fallback
        }
        return ParentIdentityKey(string: remoteHex)?.displayValue ?? remoteHex
    }

    func childDeviceInvite(for child: ChildIdentityItem) -> ChildDeviceInvite? {
        guard let identity = child.identity,
              let secret = child.secretKey,
              let parentIdentity = try? ensureParentIdentityLoaded()
        else { return nil }

        let parentKey = parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex
        let childKey = identity.publicKeyBech32 ?? identity.keyPair.publicKeyHex

        var delegationPayload: ChildDeviceInvite.DelegationPayload?
        if let delegation = child.delegation {
            delegationPayload = ChildDeviceInvite.DelegationPayload(
                delegator: delegation.delegatorPublicKey,
                delegatee: delegation.delegateePublicKey,
                conditions: delegation.conditions.encode(),
                signature: delegation.signature
            )
        }

        return ChildDeviceInvite(
            version: 1,
            childName: child.displayName,
            childPublicKey: childKey,
            childSecretKey: secret,
            parentPublicKey: parentKey,
            delegation: delegationPayload
        )
    }

    func followInvite(for child: ChildIdentityItem) -> FollowInvite? {
        guard
            let parentIdentity = parentIdentity ?? (try? ensureParentIdentityLoaded()),
            let childPublic = child.publicKey
        else {
            return nil
        }

        return FollowInvite(
            version: 1,
            childName: child.profile.name,
            childPublicKey: childPublic,
            parentPublicKey: parentIdentity.publicKeyBech32 ?? parentIdentity.publicKeyHex
        )
    }

    @discardableResult
    func submitFollowRequest(
        childId: UUID,
        targetChildKey: String,
        targetParentKey: String
    ) async -> String? {
        let trimmedTargetChild = targetChildKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetParent = targetParentKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTargetChild.isEmpty else {
            let message = "Enter the other child's public key."
            errorMessage = message
            return message
        }
        guard !trimmedTargetParent.isEmpty else {
            let message = "Enter the other parent's public key."
            errorMessage = message
            return message
        }
        guard let followerItem = childIdentities.first(where: { $0.id == childId }) else {
            let message = "Select a local child profile."
            errorMessage = message
            return message
        }
        guard isValidParentKey(trimmedTargetParent) else {
            let message = "Enter a valid parent public key (npub… or 64-char hex)."
            errorMessage = message
            return message
        }

        let localIdentity: ParentIdentity
        do {
            localIdentity = try ensureParentIdentityLoaded()
        } catch {
            let message = "Generate or import your parent key before sending follow requests."
            errorMessage = message
            return message
        }

        guard let localParentKey = ParentIdentityKey(string: localIdentity.publicKeyBech32 ?? localIdentity.publicKeyHex) else {
            let message = "Parent identity is malformed. Recreate your parent key and try again."
            errorMessage = message
            return message
        }
        guard let remoteParentKey = ParentIdentityKey(string: trimmedTargetParent) else {
            let message = "Enter a valid parent public key (npub… or 64-char hex)."
            errorMessage = message
            return message
        }

        do {
            let updated = try await environment.followCoordinator.requestFollow(
                followerProfile: followerItem.profile,
                targetChildKey: trimmedTargetChild,
                targetParentKey: trimmedTargetParent
            )
            upsertFollow(updated)
            errorMessage = nil
            loadIdentities()
            loadRelationships()
            return nil
        } catch {
            refreshRelaysOnConnectivityError(error)
            let message = error.localizedDescription
            errorMessage = message
            return message
        }
    }

    @discardableResult
    func approveFollow(_ follow: FollowModel) async -> String? {
        guard let profileItem = targetProfile(for: follow) else {
            let message = "This follow request is not for one of your child profiles."
            errorMessage = message
            return message
        }

        do {
            let updated = try await environment.followCoordinator.approveFollow(
                follow: follow,
                approvingProfile: profileItem.profile
            )
            upsertFollow(updated)
            errorMessage = nil
            loadRelationships()
            return nil
        } catch {
            refreshRelaysOnConnectivityError(error)
            let message = error.localizedDescription
            errorMessage = message
            return message
        }
    }

    @discardableResult
    func revokeFollow(_ follow: FollowModel, remoteParentKey: String) async -> String? {
        let trimmed = remoteParentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let message = "Enter the parent's key to revoke."
            errorMessage = message
            return message
        }

        do {
            let updated = try await environment.followCoordinator.revokeFollow(
                follow: follow,
                remoteParentKey: trimmed
            )
            upsertFollow(updated)
            errorMessage = nil
            loadRelationships()
            return nil
        } catch {
            refreshRelaysOnConnectivityError(error)
            let message = error.localizedDescription
            errorMessage = message
            return message
        }
    }

    func addChildProfile(name: String, theme: ThemeDescriptor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a name for the child profile."
            return
        }
        do {
            var identity = try environment.identityManager.createChildIdentity(
                name: trimmed,
                theme: theme,
                avatarAsset: theme.defaultAvatarAsset
            )
            if let delegation = identity.delegation {
                delegationCache[identity.profile.id] = delegation
            }
            loadIdentities()
            childSecretVisibility.insert(identity.profile.id)
            lastCreatedChildID = identity.profile.id
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRelaysOnConnectivityError(_ error: Error) {
        if let dmError = error as? DirectMessageOutboxError {
            switch dmError {
            case .relaysUnavailable, .sendTimedOut:
                Task {
                    await environment.syncCoordinator.refreshRelays()
                }
            default:
                break
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
                self.followRelationships = []
                self.childKeyLookup.removeAll()
                self.localParentKeyVariants.removeAll()
            }
            environment.relationshipStore.refreshAll()
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

    private func upsertFollow(_ model: FollowModel) {
        if let index = followRelationships.firstIndex(where: { $0.id == model.id }) {
            followRelationships[index] = model
        } else {
            followRelationships.append(model)
        }
        followRelationships.sort { $0.updatedAt > $1.updatedAt }
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

    struct ChildDeviceInvite: Codable, Sendable, Equatable {
        struct DelegationPayload: Codable, Sendable, Equatable {
            let delegator: String
            let delegatee: String
            let conditions: String
            let signature: String
        }

        let version: Int
        let childName: String
        let childPublicKey: String
        let childSecretKey: String
        let parentPublicKey: String
        let delegation: DelegationPayload?

        var encodedURL: String? {
            guard let data = try? JSONEncoder().encode(self) else {
                return nil
            }
            let base = data.base64EncodedString()
            var components = URLComponents()
            components.scheme = "mytube"
            components.host = "child-invite"
            components.queryItems = [
                URLQueryItem(name: "v", value: "\(version)"),
                URLQueryItem(name: "data", value: base)
            ]
            return components.url?.absoluteString
        }

        var shareText: String {
            """
            MyTube Child Device Invite: \(childName)
            Parent: \(parentPublicKey)
            Child: \(childPublicKey)

            Scan the QR or open the link below on the destination device:
            \(encodedURL ?? "")
            """
        }

        var shareItems: [Any] {
            var items: [Any] = []
            items.append(shareText)
            if let urlString = encodedURL, let url = URL(string: urlString) {
                items.append(url)
            } else if let urlString = encodedURL {
                items.append(urlString)
            }
            return items
        }

        static func decode(from string: String) -> ChildDeviceInvite? {
            if let invite = decodeURLString(string) {
                return invite
            }
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|<>\"'()[]{}"))
            let tokens = string.components(separatedBy: separators)
            for token in tokens {
                if let invite = decodeURLString(token) {
                    return invite
                }
            }
            return nil
        }

        private static func decodeURLString(_ string: String) -> ChildDeviceInvite? {
            guard let url = URL(string: string),
                  url.scheme?.caseInsensitiveCompare("mytube") == .orderedSame,
                  url.host?.caseInsensitiveCompare("child-invite") == .orderedSame,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
                  let decodedData = Data(base64Encoded: dataParam)
            else { return nil }
            return try? JSONDecoder().decode(ChildDeviceInvite.self, from: decodedData)
        }
    }

    struct FollowInvite: Codable, Sendable, Equatable {
        let version: Int
        let childName: String?
        let childPublicKey: String
        let parentPublicKey: String

        var encodedURL: String? {
            guard let data = try? JSONEncoder().encode(self) else {
                return nil
            }
            let base = data.base64EncodedString()
            var components = URLComponents()
            components.scheme = "mytube"
            components.host = "follow-invite"
            components.queryItems = [
                URLQueryItem(name: "v", value: "\(version)"),
                URLQueryItem(name: "data", value: base)
            ]
            return components.url?.absoluteString
        }

        var shareText: String {
            let nameDescriptor = childName.map { " (\($0))" } ?? ""
            return """
            MyTube Follow Invite\(nameDescriptor)
            Parent: \(parentPublicKey)
            Child: \(childPublicKey)

            Scan the QR or open the link below on the other parent's device:
            \(encodedURL ?? "")
            """
        }

        var shareItems: [Any] {
            var items: [Any] = [shareText]
            if let urlString = encodedURL, let url = URL(string: urlString) {
                items.append(url)
            } else if let urlString = encodedURL {
                items.append(urlString)
            }
            return items
        }

        static func decode(from string: String) -> FollowInvite? {
            if let invite = decodeURLString(string) {
                return invite
            }

            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }

            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|&"))
            let tokens = normalized.components(separatedBy: separators).filter { !$0.isEmpty }
            var parentValue: String?
            var childValue: String?

            for token in tokens {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].lowercased()
                let value = parts[1]
                if key == "parent" || key == "parentnpub" {
                    parentValue = value
                } else if key == "child" || key == "childnpub" {
                    childValue = value
                }
            }

            if let parentValue, let childValue {
                return FollowInvite(
                    version: 1,
                    childName: nil,
                    childPublicKey: childValue,
                    parentPublicKey: parentValue
                )
            }

            return nil
        }

        private static func decodeURLString(_ string: String) -> FollowInvite? {
            guard let url = URL(string: string),
                  url.scheme?.caseInsensitiveCompare("mytube") == .orderedSame,
                  url.host?.caseInsensitiveCompare("follow-invite") == .orderedSame,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
                  let decodedData = Data(base64Encoded: dataParam)
            else { return nil }
            return try? JSONDecoder().decode(FollowInvite.self, from: decodedData)
        }
    }
}
