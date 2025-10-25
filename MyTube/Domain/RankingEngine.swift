//
//  RankingEngine.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation

struct RankingEngine {
    enum Shelf: String, CaseIterable, Hashable {
        case forYou = "For You"
        case recent = "Recent"
        case calm = "Calm"
        case action = "Action"
        case favorites = "Favorites"
    }

    struct RankedVideo: Identifiable, Hashable {
        var id: UUID { video.id }
        let video: VideoModel
        let score: Double
    }

    struct Result {
        let ranked: [RankedVideo]
        let hero: RankedVideo?
        let shelves: [Shelf: [RankedVideo]]
    }

    func rank(
        videos: [VideoModel],
        rankingState: RankingStateModel,
        referenceDate: Date = Date()
    ) -> Result {
        guard !videos.isEmpty else {
            return Result(ranked: [], hero: nil, shelves: [:])
        }

        var baseRanked = videos.map { video in
            RankedVideo(video: video, score: baseScore(for: video, rankingState: rankingState, referenceDate: referenceDate))
        }

        baseRanked.sort { $0.score > $1.score }
        let diversified = applyDiversityPenalty(on: baseRanked)
        let explored = injectExploreSamples(into: diversified, allVideos: videos, exploreRate: rankingState.exploreRate)

        let hero = explored.first

        let shelves: [Shelf: [RankedVideo]] = [
            .forYou: explored,
            .recent: sortedByRecency(videos),
            .calm: filtered(videos, where: { $0.loudness < 0.4 }),
            .action: filtered(videos, where: { $0.loudness >= 0.4 }),
            .favorites: filtered(videos, where: { $0.liked })
        ]

        return Result(ranked: explored, hero: hero, shelves: shelves)
    }

    private func baseScore(
        for video: VideoModel,
        rankingState: RankingStateModel,
        referenceDate: Date
    ) -> Double {
        let completion = clamp(video.completionRate)
        let replay = clamp(video.replayRate)
        let recency = recencyBoost(for: video, referenceDate: referenceDate)
        let topic = topicMatch(for: video, rankingState: rankingState)
        let likeBoost = video.liked ? 1.0 : 0.0
        let fatigue = fatiguePenalty(for: video)

        return 0.4 * completion
            + 0.2 * replay
            + 0.15 * recency
            + 0.15 * topic
            + 0.25 * likeBoost
            - 0.2 * fatigue
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private func recencyBoost(for video: VideoModel, referenceDate: Date) -> Double {
        let seconds = referenceDate.timeIntervalSince(video.createdAt)
        let days = seconds / 86_400.0
        let boost = max(0.0, 1.0 - (days / 14.0))
        return clamp(boost)
    }

    private func topicMatch(for video: VideoModel, rankingState: RankingStateModel) -> Double {
        guard !video.tags.isEmpty else { return 0.0 }
        let scores = video.tags.compactMap { rankingState.topicSuccess[$0] }
        guard !scores.isEmpty else { return 0.0 }
        return clamp(scores.reduce(0.0, +) / Double(scores.count))
    }

    private func fatiguePenalty(for video: VideoModel) -> Double {
        let fatigue = Double(video.playCount) / 10.0
        return min(fatigue, 1.0)
    }

    private func applyDiversityPenalty(on ranked: [RankedVideo]) -> [RankedVideo] {
        guard ranked.count > 1 else { return ranked }

        var adjusted: [RankedVideo] = []
        for candidate in ranked {
            let penalty = adjusted
                .map { diversityPenalty(lhs: $0.video, rhs: candidate.video) }
                .max() ?? 0.0
            let revisedScore = candidate.score - penalty
            adjusted.append(RankedVideo(video: candidate.video, score: revisedScore))
        }

        return adjusted.sorted { $0.score > $1.score }
    }

    private func diversityPenalty(lhs: VideoModel, rhs: VideoModel) -> Double {
        let lhsSet = Set(lhs.tags)
        let rhsSet = Set(rhs.tags)
        guard !lhsSet.isEmpty || !rhsSet.isEmpty else { return 0.0 }
        let intersection = lhsSet.intersection(rhsSet).count
        let union = lhsSet.union(rhsSet).count
        let similarity = union == 0 ? 0.0 : Double(intersection) / Double(union)
        return similarity * 0.2
    }

    private func injectExploreSamples(
        into ranked: [RankedVideo],
        allVideos: [VideoModel],
        exploreRate: Double
    ) -> [RankedVideo] {
        guard exploreRate > 0 else { return ranked }

        let exploreCount = max(1, Int(Double(allVideos.count) * exploreRate))
        var generator = SeededGenerator(seed: UInt64(allVideos.count))
        let shuffled = allVideos.shuffled(using: &generator)
        let exploratoryVideos = shuffled.prefix(exploreCount).map { video in
            RankedVideo(video: video, score: ranked.first?.score ?? 0.5)
        }

        var blended = ranked
        for (index, exploratory) in exploratoryVideos.enumerated() {
            let insertIndex = min(blended.count, index * 3 + 2)
            blended.insert(exploratory, at: insertIndex)
        }
        return deduplicate(blended)
    }

    private func sortedByRecency(_ videos: [VideoModel]) -> [RankedVideo] {
        videos.sorted { $0.createdAt > $1.createdAt }
            .map { RankedVideo(video: $0, score: 0) }
    }

    private func filtered(
        _ videos: [VideoModel],
        where predicate: (VideoModel) -> Bool
    ) -> [RankedVideo] {
        videos.filter(predicate)
            .map { RankedVideo(video: $0, score: 0) }
    }

    private func deduplicate(_ ranked: [RankedVideo]) -> [RankedVideo] {
        var seen: Set<UUID> = []
        return ranked.filter { rankedVideo in
            if seen.contains(rankedVideo.video.id) {
                return false
            }
            seen.insert(rankedVideo.video.id)
            return true
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x4d595df4d0f33173 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
