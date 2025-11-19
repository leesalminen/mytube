//
//  KeyPackageEventEncoder.swift
//  MyTube
//
//  Created by Codex on 04/05/26.
//

import Foundation
import MDKBindings
import NostrSDK

enum KeyPackageEventEncoder {
    static func encode(result: KeyPackageResult, signingKey: NostrKeyPair) throws -> String {
        let tags = try result.tags.map { raw -> Tag in
            try Tag.parse(data: raw)
        }
        let event = try NostrEventSigner().makeEvent(
            kind: MarmotEventKind.keyPackage.nostrKind,
            tags: tags,
            content: result.keyPackage,
            keyPair: signingKey
        )
        return try event.asJson()
    }
}
