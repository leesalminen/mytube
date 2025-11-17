//
//  MarmotMessageKind.swift
//  MyTube
//
//  Created by Assistant on 03/01/26.
//

import Foundation
import NostrSDK

enum MarmotMessageKind: UInt16 {
    case videoShare = 4543
    case videoRevoke = 4544
    case videoDelete = 4545
    case like = 4546
    case report = 4547

    var nostrKind: Kind {
        Kind(kind: rawValue)
    }
}
