//
//  RemoteVideoStore.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

struct RemoteVideoModel: Identifiable, Sendable {
    enum Status: String, Sendable {
        case available
        case downloading
        case downloaded
        case failed
        case revoked
        case deleted
        case blocked
        case reported
    }

    struct CryptoEnvelope: Decodable, Sendable {
        let algorithmMedia: String
        let mediaNonce: String
        let mediaKey: String?
        let algorithmWrap: String?
        let wrap: Wrap?

        struct Wrap: Decodable, Sendable {
            let ephemeralPublicKey: String
            let wrapSalt: String
            let wrapNonce: String
            let keyWrapped: String

            private enum CodingKeys: String, CodingKey {
                case ephemeralPublicKey = "ephemeral_pub"
                case wrapSalt = "wrap_salt"
                case wrapNonce = "wrap_nonce"
                case keyWrapped = "key_wrapped"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case algorithmMedia = "alg_media"
            case mediaNonce = "nonce_media"
            case mediaKey = "media_key"
            case algorithmWrap = "alg_wrap"
            case wrap
        }
    }

    let id: String
    let ownerChild: String
    let mlsGroupId: String?
    let title: String
    let duration: Double
    let createdAt: Date
    let blobURL: URL
    let thumbURL: URL
    let crypto: CryptoEnvelope?
    let visibility: String
    let expiresAt: Date?
    let status: String
    let localMediaPath: String?
    let localThumbPath: String?
    let lastDownloadedAt: Date?
    let downloadError: String?
    let lastSyncedAt: Date
    let metadataJSON: String

    init?(entity: RemoteVideoEntity) {
        guard
            let videoId = entity.videoId,
            let ownerChild = entity.ownerChild,
            let blobURLString = entity.blobURL,
            let thumbURLString = entity.thumbURL,
            let visibility = entity.visibility,
            let status = entity.status,
            let metadataJSON = entity.metadataJSON
        else {
            return nil
        }
        guard
            let blobURL = URL(string: blobURLString),
            let thumbURL = URL(string: thumbURLString)
        else {
            return nil
        }

        var crypto: CryptoEnvelope?
        if let wrappedJSON = entity.wrappedKeyJSON,
           let data = wrappedJSON.data(using: .utf8) {
            crypto = try? JSONDecoder().decode(CryptoEnvelope.self, from: data)
        }

        id = videoId
        self.ownerChild = ownerChild
        self.mlsGroupId = entity.mlsGroupId
        title = entity.title ?? "Untitled"
        duration = entity.duration
        createdAt = entity.createdAt ?? Date()
        self.blobURL = blobURL
        self.thumbURL = thumbURL
        self.crypto = crypto
        self.visibility = visibility
        expiresAt = entity.expiresAt
        self.status = status
        localMediaPath = entity.localMediaPath
        localThumbPath = entity.localThumbPath
        lastDownloadedAt = entity.lastDownloadedAt
        downloadError = entity.downloadError
        lastSyncedAt = entity.lastSyncedAt ?? Date()
        self.metadataJSON = metadataJSON
    }

    var statusValue: Status {
        Status(rawValue: status) ?? .available
    }

    func localMediaURL(root: URL) -> URL? {
        guard let localMediaPath else { return nil }
        return root.appendingPathComponent(localMediaPath)
    }

    func localThumbURL(root: URL) -> URL? {
        guard let localThumbPath else { return nil }
        return root.appendingPathComponent(localThumbPath)
    }
}

struct RemoteShareSummary: Equatable, Sendable {
    let ownerChild: String
    let availableCount: Int
    let revokedCount: Int
    let deletedCount: Int
    let blockedCount: Int
    let lastSharedAt: Date?
}

enum RemoteVideoStoreError: Error {
    case entityDecodeFailed
}

final class RemoteVideoStore {
    private let persistence: PersistenceController
    private let jsonEncoder: JSONEncoder

    init(persistence: PersistenceController) {
        self.persistence = persistence
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        jsonEncoder = encoder
    }

    func fetchAvailableVideos() throws -> [RemoteVideoModel] {
        let request = RemoteVideoEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "status IN %@",
            ["available", "downloading", "downloaded", "failed", "revoked"]
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteVideoEntity.createdAt, ascending: false)]
        return try fetch(with: request)
    }

    func fetchAllVideos() throws -> [RemoteVideoModel] {
        let request = RemoteVideoEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteVideoEntity.createdAt, ascending: false)]
        return try fetch(with: request)
    }

    func fetchVideo(videoId: String) throws -> RemoteVideoModel? {
        let request = RemoteVideoEntity.fetchRequest()
        request.predicate = NSPredicate(format: "videoId == %@", videoId)
        request.fetchLimit = 1
        let context = persistence.viewContext
        guard let entity = try context.fetch(request).first else {
            return nil
        }
        return RemoteVideoModel(entity: entity)
    }

    func shareSummaries() throws -> [RemoteShareSummary] {
        let context = persistence.newBackgroundContext()
        var summaries: [RemoteShareSummary] = []
        var capturedError: Error?

        context.performAndWait {
            do {
                let request = RemoteVideoEntity.fetchRequest()
                let entities = try context.fetch(request)
                var builders: [String: RemoteShareAccumulator] = [:]

                for entity in entities {
                    guard let model = RemoteVideoModel(entity: entity) else { continue }
                    var builder = builders[model.ownerChild, default: RemoteShareAccumulator()]
                    builder.ingest(model: model)
                    builders[model.ownerChild] = builder
                }

                summaries = builders.map { owner, builder in
                    builder.makeSummary(owner: owner)
                }
            } catch {
                capturedError = error
            }
        }

        if let error = capturedError {
            throw error
        }
        return summaries
    }

    func updateStatus(videoId: String, status: String) throws -> RemoteVideoModel? {
        let context = persistence.newBackgroundContext()
        var model: RemoteVideoModel?
        var thrownError: Error?

        context.performAndWait {
            do {
                let request = RemoteVideoEntity.fetchRequest()
                request.predicate = NSPredicate(format: "videoId == %@", videoId)
                request.fetchLimit = 1

                guard let entity = try context.fetch(request).first else {
                    return
                }

                entity.status = status
                entity.lastSyncedAt = Date()
                try context.save()

                model = RemoteVideoModel(entity: entity)
            } catch {
                thrownError = error
            }
        }

        if let error = thrownError {
            throw error
        }
        return model
    }

    func markVideoAsBlocked(
        videoId: String,
        reason: String?,
        storagePaths: StoragePaths,
        timestamp: Date = Date()
    ) throws -> RemoteVideoModel? {
        let context = persistence.newBackgroundContext()
        var model: RemoteVideoModel?
        var thrownError: Error?
        let fileManager = FileManager.default

        context.performAndWait {
            do {
                let request = RemoteVideoEntity.fetchRequest()
                request.predicate = NSPredicate(format: "videoId == %@", videoId)
                request.fetchLimit = 1

                guard let entity = try context.fetch(request).first else {
                    return
                }

                if let mediaPath = entity.localMediaPath {
                    let fileURL = storagePaths.rootURL.appendingPathComponent(mediaPath)
                    try? fileManager.removeItem(at: fileURL)
                }
                if let thumbPath = entity.localThumbPath {
                    let fileURL = storagePaths.rootURL.appendingPathComponent(thumbPath)
                    try? fileManager.removeItem(at: fileURL)
                }

                entity.localMediaPath = nil
                entity.localThumbPath = nil
                entity.lastDownloadedAt = nil
                entity.status = RemoteVideoModel.Status.blocked.rawValue
                entity.downloadError = reason
                entity.lastSyncedAt = timestamp
                try context.save()

                model = RemoteVideoModel(entity: entity)
            } catch {
                thrownError = error
            }
        }

        if let error = thrownError {
            throw error
        }
        return model
    }

    @discardableResult
    func upsertRemoteVideoShare(
        message: VideoShareMessage,
        metadataJSON: String,
        receivedAt: Date,
        mlsGroupId: String?
    ) throws -> RemoteVideoModel {
        let context = persistence.newBackgroundContext()
        var model: RemoteVideoModel?
        var thrownError: Error?

        context.performAndWait {
            do {
                let request = RemoteVideoEntity.fetchRequest()
                request.predicate = NSPredicate(format: "videoId == %@", message.videoId)
                request.fetchLimit = 1

                let entity = try context.fetch(request).first ?? RemoteVideoEntity(context: context)
                if entity.videoId == nil {
                    entity.videoId = message.videoId
                }
                entity.ownerChild = message.ownerChild
                if let title = message.meta?.title, !title.isEmpty {
                    entity.title = title
                } else if entity.title == nil {
                    entity.title = "Untitled"
                }
                let resolvedDuration = message.meta?.duration ?? entity.duration
                entity.duration = resolvedDuration
                if let metaCreated = message.meta?.createdAtDate {
                    entity.createdAt = metaCreated
                } else if entity.createdAt == nil {
                    entity.createdAt = Date(timeIntervalSince1970: message.ts)
                }
                entity.blobURL = message.blob.url
                entity.thumbURL = message.thumb.url
                let fallbackVisibility = entity.visibility ?? "followers"
                entity.visibility = message.policy?.visibility ?? fallbackVisibility
                entity.expiresAt = message.policy?.expiresAtDate
                entity.metadataJSON = metadataJSON
                if let cryptoData = try? jsonEncoder.encode(message.crypto),
                   let cryptoString = String(data: cryptoData, encoding: .utf8) {
                    entity.wrappedKeyJSON = cryptoString
                }
                if entity.status == nil ||
                    entity.status == RemoteVideoModel.Status.revoked.rawValue ||
                    entity.status == RemoteVideoModel.Status.deleted.rawValue {
                    entity.status = RemoteVideoModel.Status.available.rawValue
                }
                entity.downloadError = nil
                entity.lastSyncedAt = receivedAt
                entity.mlsGroupId = mlsGroupId ?? entity.mlsGroupId

                try context.save()
                model = RemoteVideoModel(entity: entity)
            } catch {
                thrownError = error
            }
        }

        if let error = thrownError {
            throw error
        }
        guard let model else {
            throw RemoteVideoStoreError.entityDecodeFailed
        }
        return model
    }

    func applyLifecycleEvent(
        videoId: String,
        status: RemoteVideoModel.Status,
        reason: String?,
        storagePaths: StoragePaths,
        timestamp: Date
    ) throws -> RemoteVideoModel? {
        let context = persistence.newBackgroundContext()
        var model: RemoteVideoModel?
        var thrownError: Error?
        let fileManager = FileManager.default

        context.performAndWait {
            do {
                let request = RemoteVideoEntity.fetchRequest()
                request.predicate = NSPredicate(format: "videoId == %@", videoId)
                request.fetchLimit = 1

                guard let entity = try context.fetch(request).first else {
                    return
                }

                if let mediaPath = entity.localMediaPath {
                    let url = storagePaths.rootURL.appendingPathComponent(mediaPath)
                    try? fileManager.removeItem(at: url)
                }
                if let thumbPath = entity.localThumbPath {
                    let url = storagePaths.rootURL.appendingPathComponent(thumbPath)
                    try? fileManager.removeItem(at: url)
                }

                entity.status = status.rawValue
                entity.downloadError = reason
                entity.localMediaPath = nil
                entity.localThumbPath = nil
                entity.lastDownloadedAt = nil
                entity.lastSyncedAt = timestamp

                try context.save()
                model = RemoteVideoModel(entity: entity)
            } catch {
                thrownError = error
            }
        }

        if let error = thrownError {
            throw error
        }
        return model
    }

    // MARK: - Helpers

    private func fetch(with request: NSFetchRequest<RemoteVideoEntity>) throws -> [RemoteVideoModel] {
        let context = persistence.viewContext
        let entities = try context.fetch(request)
        return entities.compactMap(RemoteVideoModel.init(entity:))
    }
}

private struct RemoteShareAccumulator {
    var availableCount = 0
    var revokedCount = 0
    var deletedCount = 0
    var blockedCount = 0
    var lastSharedAt: Date?

    mutating func ingest(model: RemoteVideoModel) {
        switch model.statusValue {
        case .available, .downloading, .downloaded, .failed:
            availableCount += 1
        case .revoked:
            revokedCount += 1
        case .deleted:
            deletedCount += 1
        case .blocked, .reported:
            blockedCount += 1
        }

        if let current = lastSharedAt {
            if model.createdAt > current {
                lastSharedAt = model.createdAt
            }
        } else {
            lastSharedAt = model.createdAt
        }
    }

    func makeSummary(owner: String) -> RemoteShareSummary {
        RemoteShareSummary(
            ownerChild: owner,
            availableCount: availableCount,
            revokedCount: revokedCount,
            deletedCount: deletedCount,
            blockedCount: blockedCount,
            lastSharedAt: lastSharedAt
        )
    }
}
