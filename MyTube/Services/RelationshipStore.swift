//
//  RelationshipStore.swift
//  MyTube
//
//  Created by Codex on 11/15/25.
//

import Combine
import CoreData
import Foundation
import OSLog

enum RelationshipStoreError: Error {
    case entityMissing
}

final class RelationshipStore {
    private let persistence: PersistenceController
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "com.mytube", category: "RelationshipStore")
    private let followSubject: CurrentValueSubject<[FollowModel], Never>
    private var contextObserver: NSObjectProtocol?
    private let decoder: JSONDecoder

    init(persistence: PersistenceController) {
        self.persistence = persistence
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        followSubject = .init([])

        refreshFollowRelationships()

        contextObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleContextSave(notification)
        }
    }

    deinit {
        if let observer = contextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var followRelationshipsPublisher: AnyPublisher<[FollowModel], Never> {
        followSubject
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func fetchFollowRelationships() throws -> [FollowModel] {
        let request = FollowEntity.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \FollowEntity.updatedAt, ascending: false)
        ]
        let entities = try persistence.viewContext.fetch(request)
        return entities.compactMap(FollowModel.init(entity:))
    }

    func followRelationship(follower: String, target: String) throws -> FollowModel? {
        let request = FollowEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "followerChild == %@ AND targetChild == %@",
            follower,
            target
        )
        request.fetchLimit = 1
        guard let entity = try persistence.viewContext.fetch(request).first else {
            return nil
        }
        return FollowModel(entity: entity)
    }

    @discardableResult
    func upsertFollow(
        message: FollowMessage,
        updatedAt: Date,
        participantKeys: [String] = [],
        mlsGroupId: String? = nil
    ) throws -> FollowModel {
        let context = persistence.newBackgroundContext()
        let followerKey = canonicalPublicKey(message.followerChild)
        let targetKey = canonicalPublicKey(message.targetChild)
        let canonicalMessage = FollowMessage(
            followerChild: followerKey,
            targetChild: targetKey,
            approvedFrom: message.approvedFrom,
            approvedTo: message.approvedTo,
            status: message.status,
            by: message.by,
            timestamp: Date(timeIntervalSince1970: message.ts)
        )

        var result: FollowModel?
        var capturedError: Error?

        context.performAndWait {
            do {
                let followerCandidates = Array(Set([followerKey, message.followerChild.lowercased()]))
                let targetCandidates = Array(Set([targetKey, message.targetChild.lowercased()]))

                let request = FollowEntity.fetchRequest()
                request.predicate = NSPredicate(
                    format: "followerChild IN %@ AND targetChild IN %@",
                    followerCandidates,
                    targetCandidates
                )
                request.fetchLimit = 1

                let entity = try context.fetch(request).first ?? {
                    let newEntity = FollowEntity(context: context)
                    newEntity.followerChild = followerKey
                    newEntity.targetChild = targetKey
                    return newEntity
                }()

                entity.followerChild = followerKey
                entity.targetChild = targetKey
                let existingStatusValue = entity.status ?? FollowModel.Status.pending.rawValue
                let existingStatus = FollowModel.Status(rawValue: existingStatusValue) ?? .unknown
                let incomingStatus = FollowModel.Status(rawValue: canonicalMessage.status) ?? .unknown
                let shouldResetApprovals = incomingStatus == .revoked || incomingStatus == .blocked

                let resolvedApprovedFrom: Bool
                let resolvedApprovedTo: Bool

                if shouldResetApprovals {
                    resolvedApprovedFrom = canonicalMessage.approvedFrom
                    resolvedApprovedTo = canonicalMessage.approvedTo
                } else {
                    resolvedApprovedFrom = entity.approvedFrom || canonicalMessage.approvedFrom
                    resolvedApprovedTo = entity.approvedTo || canonicalMessage.approvedTo
                }

                let resolvedStatus: FollowModel.Status
                if incomingStatus == .blocked || incomingStatus == .revoked {
                    resolvedStatus = incomingStatus
                } else if resolvedApprovedFrom && resolvedApprovedTo {
                    resolvedStatus = .active
                } else if resolvedApprovedFrom || resolvedApprovedTo {
                    resolvedStatus = .pending
                } else if incomingStatus == .unknown {
                    resolvedStatus = existingStatus
                } else {
                    resolvedStatus = incomingStatus
                }

                entity.status = resolvedStatus.rawValue
                entity.approvedFrom = resolvedApprovedFrom
                entity.approvedTo = resolvedApprovedTo
                entity.updatedAt = updatedAt
                let existingMetadata = self.decodeFollowMetadata(entity.metadataJSON)
                let metadata = self.encodeFollowMetadata(
                    canonicalMessage,
                    previous: existingMetadata,
                    additionalParentKeys: participantKeys,
                    mlsGroupId: mlsGroupId
                )
                entity.metadataJSON = metadata

                try context.save()
                if let entityModel = FollowModel(entity: entity) {
                    result = entityModel
                    self.logger.debug(
                        """
                        Upserted follow follower \(entityModel.followerChild, privacy: .public) \
                        target \(entityModel.targetChild, privacy: .public) status \(entityModel.status.rawValue, privacy: .public) \
                        approvedFrom \(entityModel.approvedFrom) approvedTo \(entityModel.approvedTo) \
                        participants \(entityModel.participantParentKeys)
                        """
                    )
                }
            } catch {
                capturedError = error
            }
        }

        if let error = capturedError {
            throw error
        }
        guard let model = result else {
            throw RelationshipStoreError.entityMissing
        }
        return model
    }

    private func encodeFollowMetadata(
        _ message: FollowMessage,
        previous: FollowRecordMetadata?,
        additionalParentKeys: [String],
        mlsGroupId: String?
    ) -> String {
        var record = previous ?? FollowRecordMetadata(lastMessage: message)
        record.ingest(message: message)
        record.addParticipants(additionalParentKeys)
        if let mlsGroupId {
            record.mlsGroupId = mlsGroupId
        }
        return record.encode(using: encoder) ?? "{}"
    }

    private func decodeFollowMetadata(_ json: String?) -> FollowRecordMetadata? {
        guard let json,
              !json.isEmpty else { return nil }
        return FollowRecordMetadata.decode(from: json, decoder: decoder)
    }

    func refreshAll() {
        refreshFollowRelationships()
    }

    @MainActor
    func followKeySnapshot() -> (childKeys: Set<String>, parentKeys: Set<String>) {
        let relationships = followSubject.value
        let childKeys = Set(
            relationships.flatMap { [$0.followerChild.lowercased(), $0.targetChild.lowercased()] }
        )
        let parentKeys = Set(
            relationships.flatMap { $0.participantParentKeys.map { $0.lowercased() } }
        )
        return (childKeys, parentKeys)
    }

    private func refreshFollowRelationships() {
        let context = persistence.newBackgroundContext()
        context.perform { [weak self] in
            guard let self else { return }
            do {
                let request = FollowEntity.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(keyPath: \FollowEntity.updatedAt, ascending: false)
                ]
                var entities = try context.fetch(request)
                var didMutate = false
                for entity in entities {
                    if let key = entity.followerChild {
                        let canonical = self.canonicalPublicKey(key)
                        if canonical.caseInsensitiveCompare(key) != .orderedSame {
                            entity.followerChild = canonical
                            didMutate = true
                        }
                    }
                    if let key = entity.targetChild {
                        let canonical = self.canonicalPublicKey(key)
                        if canonical.caseInsensitiveCompare(key) != .orderedSame {
                            entity.targetChild = canonical
                            didMutate = true
                        }
                    }
                }
                if didMutate && context.hasChanges {
                    try context.save()
                    entities = try context.fetch(request)
                }
                let models = entities.compactMap(FollowModel.init(entity:))
                let deduped = Dictionary(grouping: models, by: \.id)
                    .compactMap { $0.value.max(by: { $0.updatedAt < $1.updatedAt }) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                DispatchQueue.main.async {
                    self.followSubject.send(deduped)
                }
            } catch {
                self.logger.error("Failed to refresh follow relationships: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleContextSave(_ notification: Notification) {
        var needsFollowRefresh = false

        guard let userInfo = notification.userInfo else { return }
        let keys: [String] = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey
        ]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            for object in objects {
                if object is FollowEntity {
                    needsFollowRefresh = true
                }
            }
        }

        if needsFollowRefresh {
            DispatchQueue.main.async { [weak self] in
                self?.refreshFollowRelationships()
            }
        }
    }

    private func canonicalPublicKey(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = ParentIdentityKey(string: trimmed) {
            return normalized.hex.lowercased()
        }
        if let data = Data(hexString: trimmed), data.count == 32 {
            return data.hexEncodedString().lowercased()
        }
        return trimmed.lowercased()
    }
}
