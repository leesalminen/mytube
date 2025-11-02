//
//  NostrEventSigner.swift
//  MyTube
//
//  Created by Codex on 10/26/25.
//

import Foundation
import CryptoKit
import NostrSDK

enum NostrEventSignerError: Swift.Error {
    case serializationFailed
    case signingFailed
}

struct NostrEventSigner {
    func signDelegation(
        delegatorKey: NostrKeyPair,
        delegateePublicKeyHex: String,
        conditions: String
    ) throws -> String {
        guard let messageData = "nostr:delegation:\(delegateePublicKeyHex):\(conditions)".data(using: .utf8) else {
            throw NostrEventSignerError.serializationFailed
        }
        let digest = Data(SHA256.hash(data: messageData))
        let keys = try delegatorKey.makeKeys()
        return try keys.signSchnorr(message: digest)
    }

    func makeEvent(
        kind: EventKind,
        tags: [Tag],
        content: String,
        keyPair: NostrKeyPair,
        createdAt: Foundation.Date = Foundation.Date()
    ) throws -> NostrEvent {
        var builder = NostrSDK.EventBuilder(kind: kind, content: content)
        if !tags.isEmpty {
            builder = builder.tags(tags: tags)
        }
        let timestamp = NostrSDK.Timestamp.fromSecs(secs: UInt64(createdAt.timeIntervalSince1970))
        builder = builder.customCreatedAt(createdAt: timestamp)
        let keys = try keyPair.makeKeys()
        return try builder.signWithKeys(keys: keys)
    }
}
