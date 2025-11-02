//
//  ProfileMetadataPayload.swift
//  MyTube
//
//  Created by Codex on 12/24/25.
//

import Foundation

struct ProfileMetadataPayload: Codable, Sendable {
    var name: String?
    var displayName: String?
    var about: String?
    var picture: String?
    var nip05: String?
    var wrapKey: String?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case about
        case picture
        case nip05
        case wrapKey = "mytube_wrap_key"
    }
}
