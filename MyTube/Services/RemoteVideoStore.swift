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

final class RemoteVideoStore {
    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
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

    // MARK: - Helpers

    private func fetch(with request: NSFetchRequest<RemoteVideoEntity>) throws -> [RemoteVideoModel] {
        let context = persistence.viewContext
        let entities = try context.fetch(request)
        return entities.compactMap(RemoteVideoModel.init(entity:))
    }
}
