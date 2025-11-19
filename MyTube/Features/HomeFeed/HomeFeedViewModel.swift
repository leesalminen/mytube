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

    private weak var environment: AppEnvironment?
    private var profile: ProfileModel?
    private var fetchedResultsController: NSFetchedResultsController<VideoEntity>?
    private var remoteFetchedResultsController: NSFetchedResultsController<RemoteVideoEntity>?
    private var keepAliveTask: Task<Void, Never>?
    private let keepAliveInterval: UInt64 = 60 * NSEC_PER_SEC

    func bind(to environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
        observeProfileChanges(environment)
        environment.childProfileStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSharedVideos()
            }
            .store(in: &cancellables)
        updateProfile(environment.activeProfile)

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
        let videos = baseVideos
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

        let grouped = Dictionary(grouping: visibleItems, by: { $0.ownerKey })
        var sections: [SharedRemoteSection] = grouped.map { key, videos in
            let sortedVideos = videos.sorted { $0.video.createdAt > $1.video.createdAt }
            let displayName = sortedVideos.first?.ownerDisplayName ?? fallbackOwnerLabel(for: key)
            return SharedRemoteSection(ownerDisplayName: displayName, ownerKey: key, videos: sortedVideos)
        }

        sections.sort { lhs, rhs in
            let lhsDate = lhs.latestActivity ?? Date.distantPast
            let rhsDate = rhs.latestActivity ?? Date.distantPast
            return lhsDate > rhsDate
        }

        print("   Created \(sections.count) section(s)")
        for section in sections {
            print("      Section: \(section.ownerDisplayName) - \(section.videos.count) videos")
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

    private struct DisplayContext {
        let groupName: String?
        let localProfileIds: Set<String>  // Local child profile IDs
        let remoteParentNames: [String: String]  // Remote parent key -> display name
    }
    
    private func buildDisplayContext(environment: AppEnvironment) async -> DisplayContext {
        // Get group name if we're in exactly one group
        var groupName: String?
        do {
            let groups = try await environment.mdkActor.getGroups()
            if groups.count == 1, let group = groups.first {
                groupName = group.name
            }
        } catch {
            // Ignore
        }
        
        // Get local child profile IDs (to identify if a video is from ourselves)
        var localProfileIds: Set<String> = []
        if let localProfiles = try? environment.profileStore.fetchProfiles() {
            for profile in localProfiles {
                // Profile ID as hex without dashes
                let profileIdHex = profile.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                localProfileIds.insert(profileIdHex)
            }
        }
        
        // Get remote parent names from published parent profiles
        var remoteParentNames: [String: String] = [:]
        // For now, we'll infer from the group - if not from us, show the group name
        // Later we can enhance this to fetch parent profile metadata
        
        return DisplayContext(
            groupName: groupName,
            localProfileIds: localProfileIds,
            remoteParentNames: remoteParentNames
        )
    }
    
    private func makeSharedVideo(from model: RemoteVideoModel, context: DisplayContext) -> SharedRemoteVideo {
        let display = resolveOwnerDisplay(for: model, context: context)
        let canonical = canonicalOwnerKey(for: model.ownerChild) ?? model.ownerChild
        return SharedRemoteVideo(video: model, ownerDisplayName: display, ownerKey: canonical)
    }

    private func resolveOwnerDisplay(for model: RemoteVideoModel, context: DisplayContext) -> String {
        // Strategy 1: Check if this is from ourselves
        let ownerIdNormalized = model.ownerChild.lowercased()
        if context.localProfileIds.contains(ownerIdNormalized) {
            return "My Videos"  // This is from our own profile - shouldn't show in remote section
        }
        
        // Strategy 2: Videos from remote families
        // Since we can't determine the exact remote child name (no Nostr keys),
        // show it as being from the group/family
        if let groupName = context.groupName {
            // For single group, show "Friend's Family" or the group name
            return "Shared from \(groupName)"
        }
        
        // Strategy 3: Fallback for multi-group scenarios
        return "Trusted Family"
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

    private var cancellables: Set<AnyCancellable> = []

    deinit {
        keepAliveTask?.cancel()
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

    struct SharedRemoteSection: Identifiable {
        let ownerDisplayName: String
        let ownerKey: String
        let videos: [SharedRemoteVideo]

        var id: String { ownerKey }
        var latestActivity: Date? { videos.first?.video.createdAt }
    }

    struct SharedRemoteVideo: Identifiable {
        let video: RemoteVideoModel
        let ownerDisplayName: String
        let ownerKey: String

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
