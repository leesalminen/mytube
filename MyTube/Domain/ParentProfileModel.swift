//
//  ParentProfileModel.swift
//  MyTube
//
//  Created by Codex on 12/10/25.
//

import Foundation
import CoreData

struct ParentProfileModel: Identifiable, Hashable, Sendable {
    let publicKey: String
    let name: String?
    let displayName: String?
    let about: String?
    let pictureURLString: String?
    let wrapPublicKey: Data?
    let updatedAt: Date

    var id: String { publicKey.lowercased() }

    var pictureURL: URL? {
        guard let pictureURLString else { return nil }
        return URL(string: pictureURLString)
    }

    var wrapPublicKeyBase64: String? {
        wrapPublicKey?.base64EncodedString()
    }

    init(
        publicKey: String,
        name: String?,
        displayName: String?,
        about: String?,
        pictureURLString: String?,
        wrapPublicKey: Data?,
        updatedAt: Date
    ) {
        self.publicKey = publicKey
        self.name = name
        self.displayName = displayName
        self.about = about
        self.pictureURLString = pictureURLString
        self.wrapPublicKey = wrapPublicKey
        self.updatedAt = updatedAt
    }

    init?(entity: ParentProfileEntity) {
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
            wrapPublicKey: entity.wrapPublicKey,
            updatedAt: updatedAt
        )
    }

    func updating(
        name: String? = nil,
        displayName: String? = nil,
        about: String? = nil,
        pictureURLString: String? = nil,
        wrapPublicKey: Data? = nil,
        updatedAt: Date? = nil
    ) -> ParentProfileModel {
        ParentProfileModel(
            publicKey: publicKey,
            name: name ?? self.name,
            displayName: displayName ?? self.displayName,
            about: about ?? self.about,
            pictureURLString: pictureURLString ?? self.pictureURLString,
            wrapPublicKey: wrapPublicKey ?? self.wrapPublicKey,
            updatedAt: updatedAt ?? self.updatedAt
        )
    }
}
