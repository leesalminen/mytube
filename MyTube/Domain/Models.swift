//
//  Models.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

struct ProfileModel: Identifiable, Hashable {
    let id: UUID
    var name: String
    var theme: ThemeDescriptor
    var avatarAsset: String

    init(id: UUID, name: String, theme: ThemeDescriptor, avatarAsset: String) {
        self.id = id
        self.name = name
        self.theme = theme
        self.avatarAsset = avatarAsset
    }

    init?(entity: ProfileEntity) {
        guard
            let id = entity.id,
            let name = entity.name,
            let themeRaw = entity.theme,
            let theme = ThemeDescriptor(rawValue: themeRaw),
            let avatarAsset = entity.avatarAsset
        else { return nil }
        self.init(
            id: id,
            name: name,
            theme: theme,
            avatarAsset: avatarAsset
        )
    }
}

struct VideoModel: Identifiable, Hashable {
    enum Visibility {
        case visible
        case hidden
    }

    let id: UUID
    let profileId: UUID
    var filePath: String
    var thumbPath: String
    var title: String
    var duration: TimeInterval
    var createdAt: Date
    var lastPlayedAt: Date?
    var playCount: Int
    var completionRate: Double
    var replayRate: Double
    var liked: Bool
    var hidden: Bool
    var tags: [String]
    var cvLabels: [String]
    var faceCount: Int
    var loudness: Double

    init(
        id: UUID,
        profileId: UUID,
        filePath: String,
        thumbPath: String,
        title: String,
        duration: TimeInterval,
        createdAt: Date,
        lastPlayedAt: Date?,
        playCount: Int,
        completionRate: Double,
        replayRate: Double,
        liked: Bool,
        hidden: Bool,
        tags: [String],
        cvLabels: [String],
        faceCount: Int,
        loudness: Double
    ) {
        self.id = id
        self.profileId = profileId
        self.filePath = filePath
        self.thumbPath = thumbPath
        self.title = title
        self.duration = duration
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = playCount
        self.completionRate = completionRate
        self.replayRate = replayRate
        self.liked = liked
        self.hidden = hidden
        self.tags = tags
        self.cvLabels = cvLabels
        self.faceCount = faceCount
        self.loudness = loudness
    }

    init?(entity: VideoEntity) {
        guard
            let id = entity.id,
            let profileId = entity.profileId,
            let filePath = entity.filePath,
            let thumbPath = entity.thumbPath,
            let title = entity.title,
            let createdAt = entity.createdAt,
            let tagsJSON = entity.tagsJSON,
            let labelsJSON = entity.cvLabelsJSON
        else { return nil }

        self.init(
            id: id,
            profileId: profileId,
            filePath: filePath,
            thumbPath: thumbPath,
            title: title,
            duration: entity.duration,
            createdAt: createdAt,
            lastPlayedAt: entity.lastPlayedAt,
            playCount: Int(entity.playCount),
            completionRate: entity.completionRate,
            replayRate: entity.replayRate,
            liked: entity.liked,
            hidden: entity.hidden,
            tags: Self.decodeJSON(tagsJSON),
            cvLabels: Self.decodeJSON(labelsJSON),
            faceCount: Int(entity.faceCount),
            loudness: entity.loudness
        )
    }

    private static func decodeJSON(_ string: String) -> [String] {
        guard let data = string.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }
}

struct FeedbackModel: Identifiable, Hashable {
    enum Action: String, CaseIterable {
        case like
        case skip
        case replay
        case hide
    }

    let id: UUID
    let videoId: UUID
    let action: Action
    let at: Date

    init(id: UUID, videoId: UUID, action: Action, at: Date) {
        self.id = id
        self.videoId = videoId
        self.action = action
        self.at = at
    }

    init?(entity: FeedbackEntity) {
        guard
            let id = entity.id,
            let videoId = entity.videoId,
            let actionRaw = entity.action,
            let action = Action(rawValue: actionRaw),
            let at = entity.at
        else { return nil }
        self.init(id: id, videoId: videoId, action: action, at: at)
    }
}

struct RankingStateModel: Hashable {
    let profileId: UUID
    var topicSuccess: [String: Double]
    var exploreRate: Double

    init(profileId: UUID, topicSuccess: [String: Double], exploreRate: Double) {
        self.profileId = profileId
        self.topicSuccess = topicSuccess
        self.exploreRate = exploreRate
    }

    init?(entity: RankingStateEntity) {
        guard
            let profileId = entity.profileId,
            let topicJSON = entity.topicSuccessJSON,
            let topicSuccess = RankingStateModel.decodeMap(topicJSON)
        else { return nil }
        self.init(profileId: profileId, topicSuccess: topicSuccess, exploreRate: entity.exploreRate)
    }

    private static func decodeMap(_ string: String) -> [String: Double]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }
}

enum ThemeDescriptor: String, CaseIterable {
    case ocean
    case sunset
    case forest
    case galaxy
}

struct VideoCreationRequest {
    let profileId: UUID
    let sourceURL: URL
    let thumbnailURL: URL
    let title: String
    let duration: TimeInterval
    let tags: [String]
    let cvLabels: [String]
    let faceCount: Int
    let loudness: Double
}

struct PlaybackMetricUpdate {
    let videoId: UUID
    var playCountDelta: Int = 0
    var completionRate: Double?
    var replayRate: Double?
    var liked: Bool?
    var hidden: Bool?
    var lastPlayedAt: Date?
}
