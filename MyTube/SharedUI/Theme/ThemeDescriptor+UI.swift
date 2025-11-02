//
//  ThemeDescriptor+UI.swift
//  MyTube
//
//  Created by Codex on 11/06/25.
//

import Foundation

extension ThemeDescriptor {
    var displayName: String {
        switch self {
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .forest: return "Forest"
        case .galaxy: return "Galaxy"
        }
    }

    var defaultAvatarAsset: String {
        "avatar.dolphin"
    }
}
