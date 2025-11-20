//
//  HomeFeedViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Combine
import CoreData
import Foundation

@MainActor
final class HomeFeedViewModel: NSObject, ObservableObject {
    struct RemoteShareSummary: Equatable {
        let availableCount: Int
        let downloadedCount: Int
        let lastSharedAt: Date?

        var totalCount: Int { availableCount + downloadedCount }
        var hasActivity: Bool { totalCount > 0 }

        static let empty = RemoteShareSummary(availableCount: 0, downloadedCount: 0, lastSharedAt: nil)
    }

    @Published private(set) var hero: RankingEngine.RankedVideo?
    @Published private(set) var rankedVideos: [RankingEngine.RankedVideo] = []
    @Published private(set) var shelves: [RankingEngine.Shelf: [RankingEngine.RankedVideo]] = [:]
    @Published private(set) var sharedSections: [SharedRemoteSection] = []
    @Published var presentedRemoteVideo: SharedRemoteVideo?
    @Published private(set) var error: String?
    @Published private(set) var remoteShareSummary: RemoteShareSummary = .empty
    @Published var publishingVideoIds: Set<UUID> = []

    private weak var environment: AppEnvironment?
    private var profile: ProfileModel?
    private var parentalControlsStore: ParentalControlsStore?
    private var fetchedResultsController: NSFetchedResultsController<VideoEntity>?
    private var remoteFetchedResultsController: NSFetchedResultsController<RemoteVideoEntity>?
    private var keepAliveTask: Task<Void, Never>?
    private let keepAliveInterval: UInt64 = 60 * NSEC_PER_SEC
    private var marmotObservers: [NSObjectProtocol] = []
    private let metadataDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func bind(to environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
        self.parentalControlsStore = environment.parentalControlsStore
        observeProfileChanges(environment)
        environment.childProfileStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSharedVideos()
            }
            .store(in: &cancellables)
        updateProfile(environment.activeProfile)
        installMarmotObservers()

        Task {
            await environment.syncCoordinator.start()
            await environment.syncCoordinator.refreshSubscriptions()
        }

        startKeepAlive(using: environment)
    }

    func updateProfile(_ profile: ProfileModel) {
        guard let environment else { return }
        self.profile = profile
        configureFetchedResultsController(profile: profile, environment: environment)
        configureRemoteFetchedResultsController(environment: environment)
    }

    private func observeProfileChanges(_ environment: AppEnvironment) {
        environment.$activeProfile
            .sink { [weak self] profile in
                self?.updateProfile(profile)
            }
            .store(in: &cancellables)
    }

    private func configureFetchedResultsController(profile: ProfileModel, environment: AppEnvironment) {
        fetchedResultsController?.delegate = nil

        let fetchRequest = VideoEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "profileId == %@", profile.id as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \VideoEntity.createdAt, ascending: false)]

        let controller = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: environment.persistence.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = self
        fetchedResultsController = controller

        do {
            try controller.performFetch()
            recomputeRanking()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func configureRemoteFetchedResultsController(environment: AppEnvironment) {
        remoteFetchedResultsController?.delegate = nil

        let fetchRequest = RemoteVideoEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(
            format: "status IN %@",
            [
                RemoteVideoModel.Status.available.rawValue,
                RemoteVideoModel.Status.downloading.rawValue,
                RemoteVideoModel.Status.downloaded.rawValue,
                RemoteVideoModel.Status.failed.rawValue,
                RemoteVideoModel.Status.revoked.rawValue
            ]
        )
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteVideoEntity.createdAt, ascending: false)]

        let controller = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: environment.persistence.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        controller.delegate = self
        remoteFetchedResultsController = controller

        do {
            try controller.performFetch()
            updateSharedVideos()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func recomputeRanking() {
        guard
            let environment,
            let profile,
            let entities = fetchedResultsController?.fetchedObjects
        else {
            hero = nil
            rankedVideos = []
            shelves = [:]
            return
        }

        let baseVideos = entities.compactMap(VideoModel.init(entity:))
        let videos = baseVideos.filter { $0.approvalStatus != .rejected }
        let rankingState = (try? environment.videoLibrary.fetchRankingState(profileId: profile.id)) ?? RankingStateModel(profileId: profile.id, topicSuccess: [:], exploreRate: 0.15)
        let result = environment.rankingEngine.rank(videos: videos, rankingState: rankingState)
        hero = result.hero
        rankedVideos = result.ranked
        shelves = result.shelves
    }

    private func updateSharedVideos() {
        guard let entities = remoteFetchedResultsController?.fetchedObjects else {
            print("📺 updateSharedVideos: No remoteFetchedResultsController or no fetched objects")
            sharedSections = []
            remoteShareSummary = .empty
            return
        }

        print("📺 updateSharedVideos: Found \(entities.count) remote video entities")
        
        // Build display context asynchronously
        Task { [weak self] in
            guard let self, let environment = self.environment else { return }
            let displayContext = await self.buildDisplayContext(environment: environment)
            
            await MainActor.run {
                let items = entities.compactMap { entity -> SharedRemoteVideo? in
                    guard let model = RemoteVideoModel(entity: entity) else { return nil }
                    return self.makeSharedVideo(from: model, context: displayContext)
                }
                print("   Converted to \(items.count) SharedRemoteVideo items")
                
                self.processSharedVideoItems(items)
            }
        }
    }
    
    private func processSharedVideoItems(_ items: [SharedRemoteVideo]) {

        var availableCount = 0
        var downloadedCount = 0
        var latestShareDate: Date?

        let visibleItems = items.filter { item in
            switch item.video.statusValue {
            case .blocked, .reported, .deleted:
                return false
            default:
                switch item.video.statusValue {
                case .available, .downloading:
                    availableCount += 1
                case .downloaded:
                    downloadedCount += 1
                default:
                    break
                }
                if latestShareDate == nil || item.video.createdAt > (latestShareDate ?? .distantPast) {
                    latestShareDate = item.video.createdAt
                }
                return true
            }
        }

        let grouped = Dictionary(grouping: visibleItems, by: { $0.groupId ?? $0.ownerKey })
        var sections: [SharedRemoteSection] = grouped.map { key, videos in
            let sortedVideos = videos.sorted { $0.video.createdAt > $1.video.createdAt }
            let first = sortedVideos.first
            let title = sectionTitle(from: first, fallbackKey: key)
            return SharedRemoteSection(
                id: first?.groupId ?? key,
                title: title,
                groupId: first?.groupId,
                groupName: first?.groupName,
                videos: sortedVideos
            )
        }

        sections.sort { lhs, rhs in
            let lhsDate = lhs.latestActivity ?? Date.distantPast
            let rhsDate = rhs.latestActivity ?? Date.distantPast
            return lhsDate > rhsDate
        }

        print("   Created \(sections.count) section(s)")
        for section in sections {
            print("      Section: \(section.title) - \(section.videos.count) videos")
        }
        
        sharedSections = sections
        remoteShareSummary = RemoteShareSummary(
            availableCount: availableCount,
            downloadedCount: downloadedCount,
            lastSharedAt: latestShareDate
        )
        
        print("   📊 Summary: \(availableCount) available, \(downloadedCount) downloaded")

        if sections.isEmpty {
            print("   ⚠️ No sections to display")
            presentedRemoteVideo = nil
            return
        }
        print("   ✅ Shared sections updated!")


        if let presented = presentedRemoteVideo {
            let refreshed = sections.flatMap { $0.videos }.first { $0.video.id == presented.video.id }
            if let refreshed {
                presentedRemoteVideo = refreshed
            } else {
                presentedRemoteVideo = nil
            }
        }
    }

    private func sectionTitle(from video: SharedRemoteVideo?, fallbackKey: String) -> String {
        if let name = trimmed(video?.groupName) {
            return name
        }
        if let owner = trimmed(video?.ownerDisplayName) {
            return owner
        }
        return fallbackOwnerLabel(for: fallbackKey)
    }

    private struct DisplayContext {
        let localProfileIds: Set<String>  // Local child profile IDs
        let localParentKey: String?
        let groupNames: [String: String]  // mlsGroupId -> display name
        let memberToGroup: [String: String]  // parent pubkey -> mlsGroupId
        let parentNames: [String: String]  // parent pubkey -> display name
    }
    
    private func buildDisplayContext(environment: AppEnvironment) async -> DisplayContext {
        let localParentKey = GroupNameFormatter.canonicalParentKey(try? environment.identityManager.parentIdentity()?.publicKeyHex)
        var groupNames: [String: String] = [:]
        var memberToGroup: [String: String] = [:]
        var parentNames: [String: String] = [:]

        do {
            let groups = try await environment.mdkActor.getGroups()
            for group in groups {
                let members = (try? await environment.mdkActor.getMembers(inGroup: group.mlsGroupId)) ?? []
                let friendly = GroupNameFormatter.friendlyGroupName(
                    group: group,
                    members: members,
                    localParentKey: localParentKey,
                    parentProfileStore: environment.parentProfileStore
                )
                groupNames[group.mlsGroupId] = friendly

                for member in members {
                    let canonicalMember = GroupNameFormatter.canonicalParentKey(member)
                    let key = canonicalMember ?? member.lowercased()

                    if memberToGroup[key] == nil {
                        memberToGroup[key] = group.mlsGroupId
                    }
                    if parentNames[key] == nil,
                       let name = GroupNameFormatter.parentDisplayName(for: canonicalMember ?? member, store: environment.parentProfileStore) {
                        parentNames[key] = name
                    }
                }
            }
        } catch {
            // Ignore MDK failures; we'll fall back to generic labels later.
        }

        var localProfileIds: Set<String> = []
        if let localProfiles = try? environment.profileStore.fetchProfiles() {
            for profile in localProfiles {
                let profileIdHex = profile.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                localProfileIds.insert(profileIdHex)
            }
        }

        return DisplayContext(
            localProfileIds: localProfileIds,
            localParentKey: localParentKey,
            groupNames: groupNames,
            memberToGroup: memberToGroup,
            parentNames: parentNames
        )
    }
    
    private func makeSharedVideo(from model: RemoteVideoModel, context: DisplayContext) -> SharedRemoteVideo {
        let metadata = decodeShareMessage(from: model.metadataJSON)
        let groupId = resolveGroupId(for: model, metadata: metadata, context: context)
        let groupName = resolveGroupName(for: groupId, context: context)
        let display = resolveOwnerDisplay(for: model, metadata: metadata, context: context)
        let canonical = canonicalOwnerKey(for: model.ownerChild) ?? model.ownerChild
        return SharedRemoteVideo(
            video: model,
            ownerDisplayName: display,
            ownerKey: canonical,
            groupId: groupId,
            groupName: groupName
        )
    }

    private func decodeShareMessage(from json: String) -> VideoShareMessage? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? metadataDecoder.decode(VideoShareMessage.self, from: data)
    }

    private func resolveGroupId(for model: RemoteVideoModel, metadata: VideoShareMessage?, context: DisplayContext) -> String? {
        if let stored = model.mlsGroupId, !stored.isEmpty {
            return stored
        }
        if let senderKey = canonicalParentKey(metadata?.by),
           let groupId = context.memberToGroup[senderKey] {
            return groupId
        }
        if let senderKey = metadata?.by.lowercased(),
           let groupId = context.memberToGroup[senderKey] {
            return groupId
        }
        return nil
    }

    private func resolveGroupName(for groupId: String?, context: DisplayContext) -> String? {
        guard let groupId else { return nil }
        return context.groupNames[groupId]
    }

    private func resolveOwnerDisplay(
        for model: RemoteVideoModel,
        metadata: VideoShareMessage?,
        context: DisplayContext
    ) -> String {
        let ownerIdNormalized = model.ownerChild.lowercased()
        if context.localProfileIds.contains(ownerIdNormalized) {
            return "My Videos"
        }

        if let childName = trimmed(metadata?.childName) {
            return childName
        }

        if let senderKey = canonicalParentKey(metadata?.by),
           senderKey == context.localParentKey {
            return "My Videos"
        }

        if let senderKey = canonicalParentKey(metadata?.by),
           let parentName = context.parentNames[senderKey] {
            return parentName
        }

        if let senderKey = metadata?.by.lowercased(),
           let parentName = context.parentNames[senderKey] {
            return parentName
        }

        if let groupName = resolveGroupName(for: resolveGroupId(for: model, metadata: metadata, context: context), context: context) {
            return groupName
        }

        if let senderKey = metadata?.by {
            return fallbackOwnerLabel(for: senderKey)
        }

        return fallbackOwnerLabel(for: model.ownerChild)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func fallbackOwnerLabel(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }

        let lowercase = trimmed.lowercased()
        if lowercase.hasPrefix(NIP19Kind.npub.rawValue) {
            let prefix = trimmed.prefix(12)
            let suffix = trimmed.suffix(4)
            return "\(prefix)…\(suffix)"
        }

        if let data = Data(hexString: trimmed),
           let npub = try? NIP19.encodePublicKey(data) {
            let prefix = npub.prefix(12)
            let suffix = npub.suffix(4)
            return "\(prefix)…\(suffix)"
        }

        if trimmed.count > 12 {
            return "\(trimmed.prefix(8))…"
        }
        return trimmed
    }

    private func canonicalParentKey(_ value: String?) -> String? {
        guard let value else { return nil }
        return ParentIdentityKey(string: value)?.hex.lowercased()
    }

    private func canonicalOwnerKey(for key: String) -> String? {
        guard let environment else { return nil }
        return environment.childProfileStore.canonicalKey(key)
    }

    func handleRemoteVideoTap(_ item: SharedRemoteVideo) {
        guard let environment else { return }

        switch item.video.statusValue {
        case .downloaded:
            presentedRemoteVideo = item
        case .available, .failed:
            guard let profile else { return }
            error = nil
            let profileId = profile.id
            let videoId = item.video.id
            Task { [weak self, environment] in
                do {
                    let updated = try await environment.remoteVideoDownloader.download(videoId: videoId, profileId: profileId)
                    guard let self else { return }
                    let displayContext = await self.buildDisplayContext(environment: environment)
                    await MainActor.run {
                        let shared = self.makeSharedVideo(from: updated, context: displayContext)
                        self.presentedRemoteVideo = shared
                        self.error = nil
                    }
                } catch {
                    let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run {
                        self?.error = description
                    }
                }
            }
        case .downloading:
            break
        case .revoked:
            error = "This video was revoked by the sender."
        case .deleted:
            error = "This video was deleted."
        case .blocked:
            error = "This video is blocked."
        case .reported:
            error = "This video is being reviewed."
        }
    }

    func refresh() async {
        guard let environment else { return }
        print("🔄 HomeFeed.refresh() called")
        error = nil
        
        // Refresh Marmot messages from MDK
        print("   📬 Refreshing Marmot messages...")
        await environment.marmotProjectionStore.refreshAll()
        
        // Refresh Nostr subscriptions
        print("   📡 Refreshing subscriptions...")
        await environment.syncCoordinator.refreshSubscriptions()
        
        // Relationship store removed - using MDK groups directly
        print("   🎬 Recomputing ranking...")
        recomputeRanking()
        
        print("   📺 Updating shared videos...")
        updateSharedVideos()
        
        print("✅ HomeFeed.refresh() completed")
    }

    func publishVideo(_ videoId: UUID, pin: String) async throws {
        guard let environment else { return }
        guard try environment.parentAuth.validate(pin: pin) else {
            throw ParentAuthError.invalidPIN
        }

        publishingVideoIds.insert(videoId)
        defer { publishingVideoIds.remove(videoId) }

        try await environment.videoShareCoordinator.publishVideo(videoId)
    }

    private var cancellables: Set<AnyCancellable> = []

    deinit {
        keepAliveTask?.cancel()
        for observer in marmotObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startKeepAlive(using environment: AppEnvironment) {
        let coordinator = environment.syncCoordinator
        let interval = keepAliveInterval
        keepAliveTask?.cancel()
        keepAliveTask = Task.detached {
            while !Task.isCancelled {
                await coordinator.refreshSubscriptions()
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
            }
        }
    }

    private func installMarmotObservers() {
        let center = NotificationCenter.default
        let stateObserver = center.addObserver(
            forName: .marmotStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateSharedVideos()
        }
        let messagesObserver = center.addObserver(
            forName: .marmotMessagesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateSharedVideos()
        }
        marmotObservers.append(contentsOf: [stateObserver, messagesObserver])
    }

    struct SharedRemoteSection: Identifiable {
        let id: String
        let title: String
        let groupId: String?
        let groupName: String?
        let videos: [SharedRemoteVideo]

        var latestActivity: Date? { videos.first?.video.createdAt }
    }

    struct SharedRemoteVideo: Identifiable {
        let video: RemoteVideoModel
        let ownerDisplayName: String
        let ownerKey: String
        let groupId: String?
        let groupName: String?

        var id: String { video.id }
    }
}

extension HomeFeedViewModel: NSFetchedResultsControllerDelegate {
    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if controller === self.fetchedResultsController {
                self.recomputeRanking()
            } else if controller === self.remoteFetchedResultsController {
                self.updateSharedVideos()
            }
        }
    }
}
