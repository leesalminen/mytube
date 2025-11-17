//
//  MarmotEventKind.swift
//  MyTube
//
//  Created by Codex on 02/16/26.
//

import Foundation
import NostrSDK

enum MarmotEventKind: UInt16, CaseIterable {
    case keyPackage = 443
    case welcome = 444
    case group = 445
    case giftWrap = 1059

    var nostrKind: Kind {
        Kind(kind: UInt16(rawValue))
    }

    static var welcomeKinds: [Kind] {
        [MarmotEventKind.welcome, MarmotEventKind.giftWrap].map(\.nostrKind)
    }

    static var membershipKinds: [Kind] {
        [MarmotEventKind.group].map(\.nostrKind)
    }

    static var keyPackageKinds: [Kind] {
        [MarmotEventKind.keyPackage].map(\.nostrKind)
    }
}
