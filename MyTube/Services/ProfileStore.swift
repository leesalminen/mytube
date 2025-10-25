//
//  ProfileStore.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreData
import Foundation

enum ProfileStoreError: Error {
    case entityMissing
}

final class ProfileStore: ObservableObject {
    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func fetchProfiles() throws -> [ProfileModel] {
        let request = ProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ProfileEntity.name, ascending: true)]
        let entities = try persistence.viewContext.fetch(request)
        return entities.compactMap(ProfileModel.init(entity:))
    }

    func createProfile(name: String, theme: ThemeDescriptor, avatarAsset: String) throws -> ProfileModel {
        let entity = ProfileEntity(context: persistence.viewContext)
        entity.id = UUID()
        entity.name = name
        entity.theme = theme.rawValue
        entity.avatarAsset = avatarAsset
        try persistence.viewContext.save()
        guard let model = ProfileModel(entity: entity) else {
            throw ProfileStoreError.entityMissing
        }
        return model
    }

    func updateProfile(_ model: ProfileModel) throws {
        let request = ProfileEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", model.id as CVarArg)
        request.fetchLimit = 1
        guard let entity = try persistence.viewContext.fetch(request).first else {
            throw ProfileStoreError.entityMissing
        }
        entity.name = model.name
        entity.theme = model.theme.rawValue
        entity.avatarAsset = model.avatarAsset
        try persistence.viewContext.save()
    }
}
