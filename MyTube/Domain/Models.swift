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

extension ProfileModel {
    static func placeholder() -> ProfileModel {
        ProfileModel(
            id: UUID(),
            name: "",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
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

struct FollowRecordMetadata: Codable, Sendable {
    var lastMessage: FollowMessage
    var participantParentKeys: [String]

    init(lastMessage: FollowMessage, participantParentKeys: [String] = []) {
        self.lastMessage = lastMessage
        self.participantParentKeys = participantParentKeys
        normalizeParticipants()
        ingest(message: lastMessage)
    }

    mutating func ingest(message: FollowMessage) {
        lastMessage = message
        guard let normalized = ParentIdentityKey(string: message.by)?.hex.lowercased() else { return }
        if !participantParentKeys.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
            participantParentKeys.append(normalized)
            participantParentKeys.sort()
        }
    }

    mutating func addParticipants(_ keys: [String]) {
        for key in keys {
            guard let normalized = ParentIdentityKey(string: key)?.hex.lowercased() else { continue }
            if !participantParentKeys.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                participantParentKeys.append(normalized)
            }
        }
        participantParentKeys.sort()
    }

    mutating func normalizeParticipants() {
        var unique: Set<String> = []
        participantParentKeys = participantParentKeys.compactMap { key in
            guard let normalized = ParentIdentityKey(string: key)?.hex.lowercased() else { return nil }
            guard unique.insert(normalized).inserted == true else { return nil }
            return normalized
        }.sorted()
    }

    static func decode(from json: String, decoder: JSONDecoder) -> FollowRecordMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        if let record = try? decoder.decode(FollowRecordMetadata.self, from: data) {
            var normalized = record
            normalized.normalizeParticipants()
            normalized.ingest(message: normalized.lastMessage)
            return normalized
        }

        if let message = try? decoder.decode(FollowMessage.self, from: data) {
            return FollowRecordMetadata(lastMessage: message)
        }

        return nil
    }

    func encode(using encoder: JSONEncoder) -> String? {
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

struct FollowModel: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable {
        case pending
        case active
        case revoked
        case blocked
        case unknown
    }

    let followerChild: String
    let targetChild: String
    let approvedFrom: Bool
    let approvedTo: Bool
    let status: Status
    let updatedAt: Date
    let metadataJSON: String?
    let lastMessage: FollowMessage?
    let participantParentKeys: [String]

    var id: String { "\(followerChild)|\(targetChild)" }

    var isFullyApproved: Bool {
        approvedFrom && approvedTo && status == .active
    }

    init(
        followerChild: String,
        targetChild: String,
        approvedFrom: Bool,
        approvedTo: Bool,
        status: String,
        updatedAt: Date,
        metadataJSON: String?
    ) {
        self.followerChild = followerChild
        self.targetChild = targetChild
        self.approvedFrom = approvedFrom
        self.approvedTo = approvedTo
        self.status = Status(rawValue: status) ?? .unknown
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON

        if let metadataJSON,
           let record = FollowModel.decodeMetadata(metadataJSON) {
            self.lastMessage = record.lastMessage
            self.participantParentKeys = record.participantParentKeys
        } else {
            self.lastMessage = nil
            if let metadataJSON,
               let fallbackKeys = FollowModel.extractParentKeys(from: metadataJSON) {
                self.participantParentKeys = fallbackKeys
            } else {
                self.participantParentKeys = []
            }
        }
    }

    init?(entity: FollowEntity) {
        guard
            let followerChild = entity.followerChild,
            let targetChild = entity.targetChild,
            let status = entity.status,
            let updatedAt = entity.updatedAt
        else {
            return nil
        }

        self.init(
            followerChild: followerChild,
            targetChild: targetChild,
            approvedFrom: entity.approvedFrom,
            approvedTo: entity.approvedTo,
            status: status,
            updatedAt: updatedAt,
            metadataJSON: entity.metadataJSON
        )
    }

    static func == (lhs: FollowModel, rhs: FollowModel) -> Bool {
        lhs.followerChild == rhs.followerChild &&
            lhs.targetChild == rhs.targetChild &&
            lhs.approvedFrom == rhs.approvedFrom &&
            lhs.approvedTo == rhs.approvedTo &&
            lhs.status == rhs.status &&
            lhs.updatedAt == rhs.updatedAt &&
            lhs.metadataJSON == rhs.metadataJSON &&
            lhs.participantParentKeys == rhs.participantParentKeys
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(followerChild)
        hasher.combine(targetChild)
        hasher.combine(approvedFrom)
        hasher.combine(approvedTo)
        hasher.combine(status)
        hasher.combine(updatedAt)
        hasher.combine(metadataJSON)
        hasher.combine(participantParentKeys)
    }

    func matchesTarget(childHex: String) -> Bool {
        guard let normalized = FollowModel.normalizePublicKey(targetChild) else { return false }
        return normalized.caseInsensitiveCompare(childHex) == .orderedSame
    }

    func remoteParentKeys(localParentHex: String) -> [String] {
        let local = localParentHex.lowercased()
        return participantParentKeys.filter { $0.caseInsensitiveCompare(local) != .orderedSame }
    }

    func followerChildHex() -> String? {
        FollowModel.normalizePublicKey(followerChild)
    }

    func targetChildHex() -> String? {
        FollowModel.normalizePublicKey(targetChild)
    }

    private static func decodeMetadata(_ json: String) -> FollowRecordMetadata? {
        let decoder = makeMetadataDecoder()
        return FollowRecordMetadata.decode(from: json, decoder: decoder)
    }

    private static func extractParentKeys(from json: String) -> [String]? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        var keys: Set<String> = []
        if let pubkey = object["pubkey"] as? String,
           let normalized = ParentIdentityKey(string: pubkey)?.hex.lowercased() {
            keys.insert(normalized)
        }

        if let tags = object["tags"] as? [[Any]] {
            for tag in tags {
                guard tag.count >= 2,
                      let name = tag[0] as? String,
                      name.caseInsensitiveCompare("p") == .orderedSame,
                      let value = tag[1] as? String,
                      let normalized = ParentIdentityKey(string: value)?.hex.lowercased()
                else { continue }
                keys.insert(normalized)
            }
        }

        return keys.isEmpty ? nil : Array(keys).sorted()
    }

    private static func makeMetadataDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func normalizePublicKey(_ input: String) -> String? {
        ParentIdentityKey(string: input)?.hex.lowercased()
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
