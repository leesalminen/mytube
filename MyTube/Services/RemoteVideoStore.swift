//
//  RemoteVideoStore.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

struct RemoteVideoModel: Identifiable, Sendable {
    struct CryptoEnvelope: Decodable, Sendable {
        let algorithmMedia: String
        let mediaNonce: String
        let algorithmWrap: String
        let wrap: Wrap

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
        lastSyncedAt = entity.lastSyncedAt ?? Date()
        self.metadataJSON = metadataJSON
    }
}

final class RemoteVideoStore {
    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func fetchAvailableVideos() throws -> [RemoteVideoModel] {
        let request = RemoteVideoEntity.fetchRequest()
        request.predicate = NSPredicate(format: "status == %@", "available")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteVideoEntity.createdAt, ascending: false)]
        return try fetch(with: request)
    }

    func fetchAllVideos() throws -> [RemoteVideoModel] {
        let request = RemoteVideoEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \RemoteVideoEntity.createdAt, ascending: false)]
        return try fetch(with: request)
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

    // MARK: - Helpers

    private func fetch(with request: NSFetchRequest<RemoteVideoEntity>) throws -> [RemoteVideoModel] {
        let context = persistence.viewContext
        let entities = try context.fetch(request)
        return entities.compactMap(RemoteVideoModel.init(entity:))
    }
}
