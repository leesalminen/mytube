//
//  ChildProfileStore.swift
//  MyTube
//
//  Created by Codex on 12/24/25.
//

import Combine
import CoreData
import Foundation
import OSLog

enum ChildProfileStoreError: Error {
    case entityMissing
    case invalidKey
}

final class ChildProfileStore: ObservableObject {
    private let persistence: PersistenceController
    private let logger = Logger(subsystem: "com.mytube", category: "ChildProfileStore")

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func profile(for key: String) throws -> ChildProfileModel? {
        guard let canonical = canonicalKey(key) else {
            throw ChildProfileStoreError.invalidKey
        }
        let request = ChildProfileEntity.fetchRequest()
        request.predicate = NSPredicate(format: "publicKey == %@", canonical)
        request.fetchLimit = 1
        guard let entity = try persistence.viewContext.fetch(request).first else {
            return nil
        }
        return ChildProfileModel(entity: entity)
    }

    func upsertProfile(
        publicKey key: String,
        name: String?,
        displayName: String?,
        about: String?,
        pictureURLString: String?,
        updatedAt: Date,
        in context: NSManagedObjectContext? = nil
    ) throws -> ChildProfileModel {
        guard let canonical = canonicalKey(key) else {
            throw ChildProfileStoreError.invalidKey
        }

        let targetContext: NSManagedObjectContext
        let isExternal: Bool

        if let context {
            targetContext = context
            isExternal = true
        } else {
            targetContext = persistence.newBackgroundContext()
            isExternal = false
        }

        var result: ChildProfileModel?
        var didModify = false
        var capturedError: Error?

        let work = {
            do {
                let request = ChildProfileEntity.fetchRequest()
                request.predicate = NSPredicate(format: "publicKey == %@", canonical)
                request.fetchLimit = 1

                let entity: ChildProfileEntity
                if let existing = try targetContext.fetch(request).first {
                    if let existingUpdatedAt = existing.updatedAt,
                       existingUpdatedAt >= updatedAt {
                        result = ChildProfileModel(entity: existing)
                        return
                    }
                    entity = existing
                } else {
                    entity = ChildProfileEntity(context: targetContext)
                    entity.publicKey = canonical
                }

                entity.name = name
                entity.displayName = displayName
                entity.about = about
                entity.pictureURL = pictureURLString
                entity.updatedAt = updatedAt

                if targetContext.hasChanges {
                    try targetContext.save()
                    didModify = true
                }
                result = ChildProfileModel(entity: entity)
            } catch {
                capturedError = error
                self.logger.error("Failed to upsert child profile \(canonical, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if isExternal {
            work()
        } else {
            targetContext.performAndWait(work)
        }

        if let error = capturedError {
            throw error
        }
        guard let model = result else {
            throw ChildProfileStoreError.entityMissing
        }
        if didModify {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
        return model
    }

    func allProfiles() throws -> [ChildProfileModel] {
        let request = ChildProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChildProfileEntity.updatedAt, ascending: false)]
        return try persistence.viewContext.fetch(request).compactMap(ChildProfileModel.init(entity:))
    }

    func canonicalKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Handle 32-byte (64 char) hex strings (Nostr pubkeys)
        if let data = Data(hexString: trimmed), data.count == 32 {
            return data.hexEncodedString().lowercased()
        }

        // Handle npub format
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix(NIP19Kind.npub.rawValue) {
            guard let decoded = try? NIP19.decode(lowercased), decoded.kind == .npub else {
                return nil
            }
            return decoded.data.hexEncodedString().lowercased()
        }

        // Handle UUIDs (child profile IDs) - either with or without dashes
        // UUIDs are 128-bit (32 hex chars), shorter than Nostr keys (256-bit / 64 hex chars)
        let withoutDashes = trimmed.replacingOccurrences(of: "-", with: "")
        if withoutDashes.count == 32, let _ = Data(hexString: withoutDashes) {
            // Valid UUID format
            return withoutDashes.lowercased()
        }

        return nil
    }
}
