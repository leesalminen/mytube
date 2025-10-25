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
    @Published private(set) var hero: RankingEngine.RankedVideo?
    @Published private(set) var rankedVideos: [RankingEngine.RankedVideo] = []
    @Published private(set) var shelves: [RankingEngine.Shelf: [RankingEngine.RankedVideo]] = [:]
    @Published private(set) var sharedVideos: [RemoteVideoModel] = []
    @Published private(set) var error: String?

    private weak var environment: AppEnvironment?
    private var profile: ProfileModel?
    private var fetchedResultsController: NSFetchedResultsController<VideoEntity>?
    private var remoteFetchedResultsController: NSFetchedResultsController<RemoteVideoEntity>?

    func bind(to environment: AppEnvironment) {
        guard self.environment == nil else { return }
        self.environment = environment
        observeProfileChanges(environment)
        updateProfile(environment.activeProfile)
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
        fetchRequest.predicate = NSPredicate(format: "status == %@", "available")
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
        let videos: [VideoModel]
        if environment.calmModeEnabled {
            videos = baseVideos.filter { $0.loudness < 0.4 }
        } else {
            videos = baseVideos
        }
        let rankingState = (try? environment.videoLibrary.fetchRankingState(profileId: profile.id)) ?? RankingStateModel(profileId: profile.id, topicSuccess: [:], exploreRate: 0.15)
        let result = environment.rankingEngine.rank(videos: videos, rankingState: rankingState)
        hero = result.hero
        rankedVideos = result.ranked
        shelves = result.shelves
    }

    private func updateSharedVideos() {
        guard let entities = remoteFetchedResultsController?.fetchedObjects else {
            sharedVideos = []
            return
        }
        sharedVideos = entities.compactMap(RemoteVideoModel.init(entity:))
    }

    private var cancellables: Set<AnyCancellable> = []
}

extension HomeFeedViewModel: NSFetchedResultsControllerDelegate {
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        if controller === fetchedResultsController {
            recomputeRanking()
        } else if controller === remoteFetchedResultsController {
            updateSharedVideos()
        }
    }
}
