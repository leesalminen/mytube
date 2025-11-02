//
//  DirectMessageModels.swift
//  MyTube
//
//  Created by Codex on 10/26/25.
//

import Foundation

enum DirectMessageKind: String, Codable, CaseIterable, Sendable {
    case follow = "mytube/follow"
    case videoShare = "mytube/video_share"
    case videoRevoke = "mytube/video_revoke"
    case videoDelete = "mytube/video_delete"
    case like = "mytube/like"
    case report = "mytube/report"
}

struct DirectMessageEnvelope: Codable, Sendable {
    let t: String
}

struct FollowMessage: Codable, Sendable {
    let t: String
    let followerChild: String
    let targetChild: String
    let approvedFrom: Bool
    let approvedTo: Bool
    let status: String
    let by: String
    let ts: Double

    init(
        followerChild: String,
        targetChild: String,
        approvedFrom: Bool,
        approvedTo: Bool,
        status: String,
        by: String,
        timestamp: Date
    ) {
        self.t = DirectMessageKind.follow.rawValue
        self.followerChild = followerChild
        self.targetChild = targetChild
        self.approvedFrom = approvedFrom
        self.approvedTo = approvedTo
        self.status = status
        self.by = by
        self.ts = timestamp.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case followerChild = "follower_child"
        case targetChild = "target_child"
        case approvedFrom
        case approvedTo
        case status
        case by
        case ts
    }
}

struct VideoShareMessage: Codable, Sendable {
    struct Meta: Codable, Sendable {
        let title: String?
        let duration: Double?
        let createdAt: Double?

        init(title: String?, duration: Double?, createdAt: Date?) {
            self.title = title
            self.duration = duration
            self.createdAt = createdAt?.timeIntervalSince1970
        }

        private enum CodingKeys: String, CodingKey {
            case title
            case duration = "dur"
            case createdAt = "created_at"
        }

        var createdAtDate: Date? {
            guard let createdAt else { return nil }
            return Date(timeIntervalSince1970: createdAt)
        }
    }

    struct Blob: Codable, Sendable {
        let url: String
        let mime: String
        let length: Int?
        let key: String?

        init(url: String, mime: String, length: Int?, key: String? = nil) {
            self.url = url
            self.mime = mime
            self.length = length
            self.key = key
        }

        private enum CodingKeys: String, CodingKey {
            case url
            case mime
            case length = "len"
            case key
        }
    }

    struct Crypto: Codable, Sendable {
        struct Wrap: Codable, Sendable {
            let ephemeralPub: String
            let wrapSalt: String
            let wrapNonce: String
            let keyWrapped: String

            init(ephemeralPub: String, wrapSalt: String, wrapNonce: String, keyWrapped: String) {
                self.ephemeralPub = ephemeralPub
                self.wrapSalt = wrapSalt
                self.wrapNonce = wrapNonce
                self.keyWrapped = keyWrapped
            }

            private enum CodingKeys: String, CodingKey {
                case ephemeralPub = "ephemeral_pub"
                case wrapSalt = "wrap_salt"
                case wrapNonce = "wrap_nonce"
                case keyWrapped = "key_wrapped"
            }
        }

        let algMedia: String
        let nonceMedia: String
        let mediaKey: String?
        let algWrap: String?
        let wrap: Wrap?

        init(
            algMedia: String,
            nonceMedia: String,
            mediaKey: String?,
            algWrap: String? = nil,
            wrap: Wrap? = nil
        ) {
            self.algMedia = algMedia
            self.nonceMedia = nonceMedia
            self.mediaKey = mediaKey
            self.algWrap = algWrap
            self.wrap = wrap
        }

        private enum CodingKeys: String, CodingKey {
            case algMedia = "alg_media"
            case nonceMedia = "nonce_media"
            case mediaKey = "media_key"
            case algWrap = "alg_wrap"
            case wrap
        }
    }

    struct Policy: Codable, Sendable {
        let visibility: String?
        let expiresAt: Double?
        let version: Int?

        init(visibility: String?, expiresAt: Date?, version: Int?) {
            self.visibility = visibility
            self.expiresAt = expiresAt?.timeIntervalSince1970
            self.version = version
        }

        private enum CodingKeys: String, CodingKey {
            case visibility
            case expiresAt = "expires_at"
            case version
        }

        var expiresAtDate: Date? {
            guard let expiresAt else { return nil }
            return Date(timeIntervalSince1970: expiresAt)
        }
    }

    let t: String
    let videoId: String
    let ownerChild: String
    let meta: Meta?
    let blob: Blob
    let thumb: Blob
    let crypto: Crypto
    let policy: Policy?
    let by: String
    let ts: Double

    init(
        videoId: String,
        ownerChild: String,
        meta: Meta?,
        blob: Blob,
        thumb: Blob,
        crypto: Crypto,
        policy: Policy?,
        by: String,
        timestamp: Date
    ) {
        self.t = DirectMessageKind.videoShare.rawValue
        self.videoId = videoId
        self.ownerChild = ownerChild
        self.meta = meta
        self.blob = blob
        self.thumb = thumb
        self.crypto = crypto
        self.policy = policy
        self.by = by
        self.ts = timestamp.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case ownerChild = "owner_child"
        case meta
        case blob
        case thumb
        case crypto
        case policy
        case by
        case ts
    }
}

struct VideoLifecycleMessage: Codable, Sendable {
    let t: String
    let videoId: String
    let reason: String?
    let by: String
    let ts: Double

    init(kind: DirectMessageKind, videoId: String, reason: String?, by: String, timestamp: Date) {
        self.t = kind.rawValue
        self.videoId = videoId
        self.reason = reason
        self.by = by
        self.ts = timestamp.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case reason
        case by
        case ts
    }
}

struct LikeMessage: Codable, Sendable {
    let t: String
    let videoId: String
    let viewerChild: String
    let by: String
    let ts: Double

    init(videoId: String, viewerChild: String, by: String, timestamp: Date) {
        self.t = DirectMessageKind.like.rawValue
        self.videoId = videoId
        self.viewerChild = viewerChild
        self.by = by
        self.ts = timestamp.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case viewerChild = "viewer_child"
        case by
        case ts
    }
}

struct ReportMessage: Codable, Sendable {
    let t: String
    let videoId: String
    let subjectChild: String
    let reason: String
    let by: String
    let ts: Double

    init(videoId: String, subjectChild: String, reason: String, by: String, timestamp: Date) {
        self.t = DirectMessageKind.report.rawValue
        self.videoId = videoId
        self.subjectChild = subjectChild
        self.reason = reason
        self.by = by
        self.ts = timestamp.timeIntervalSince1970
    }

    private enum CodingKeys: String, CodingKey {
        case t
        case videoId = "video_id"
        case subjectChild = "subject_child"
        case reason
        case by
        case ts
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard nextIndex <= cleaned.endIndex else { return nil }
            let byteString = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
