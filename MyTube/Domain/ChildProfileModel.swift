//
//  ChildProfileModel.swift
//  MyTube
//
//  Created by Codex on 12/24/25.
//

import Foundation
import CoreData

struct ChildProfileModel: Identifiable, Hashable, Sendable {
    let publicKey: String
    let name: String?
    let displayName: String?
    let about: String?
    let pictureURLString: String?
    let updatedAt: Date

    var id: String { publicKey.lowercased() }

    var bestName: String? {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let name, !name.isEmpty {
            return name
        }
        return nil
    }

    var pictureURL: URL? {
        guard let pictureURLString else { return nil }
        return URL(string: pictureURLString)
    }

    init(
        publicKey: String,
        name: String?,
        displayName: String?,
        about: String?,
        pictureURLString: String?,
        updatedAt: Date
    ) {
        self.publicKey = publicKey
        self.name = name
        self.displayName = displayName
        self.about = about
        self.pictureURLString = pictureURLString
        self.updatedAt = updatedAt
    }

    init?(entity: ChildProfileEntity) {
        guard
            let key = entity.publicKey,
            let updatedAt = entity.updatedAt
        else {
            return nil
        }
        self.init(
            publicKey: key,
            name: entity.name,
            displayName: entity.displayName,
            about: entity.about,
            pictureURLString: entity.pictureURL,
            updatedAt: updatedAt
        )
    }

    func updating(
        name: String? = nil,
        displayName: String? = nil,
        about: String? = nil,
        pictureURLString: String? = nil,
        updatedAt: Date? = nil
    ) -> ChildProfileModel {
        ChildProfileModel(
            publicKey: publicKey,
            name: name ?? self.name,
            displayName: displayName ?? self.displayName,
            about: about ?? self.about,
            pictureURLString: pictureURLString ?? self.pictureURLString,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }
}
