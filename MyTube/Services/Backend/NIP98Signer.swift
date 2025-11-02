//
//  NIP98Signer.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import CryptoKit
import Foundation
import NostrSDK

enum NIP98SignerError: Error {
    case jsonEncodingFailed
}

struct NIP98Signer {
    private let keyStore: KeychainKeyStore
    private let signer: NostrEventSigner

    init(keyStore: KeychainKeyStore, signer: NostrEventSigner = NostrEventSigner()) {
        self.keyStore = keyStore
        self.signer = signer
    }

    func authorizationHeader(
        method: String,
        url: URL,
        challenge: String?,
        body: Data?
    ) throws -> String {
        let keyPair = try keyStore.ensureParentKeyPair()
        let uppercasedMethod = method.uppercased()
        let pathAndQuery: String = {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.path
            }
            let path = components.path.isEmpty ? "/" : components.path
            if let query = components.percentEncodedQuery, !query.isEmpty {
                return "\(path)?\(query)"
            }
            return path
        }()
        var tags: [Tag] = [
            NostrTagBuilder.make(name: "u", value: url.absoluteString),
            NostrTagBuilder.make(name: "method", value: uppercasedMethod)
        ]

        if let challenge {
            tags.append(NostrTagBuilder.make(name: "challenge", value: challenge))
        }

        if let body, !body.isEmpty {
            let hash = SHA256.hash(data: body)
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            tags.append(NostrTagBuilder.make(name: "payload", value: hex))
        }

        let content: String
        if let challenge {
            content = "challenge=\(challenge)&method=\(uppercasedMethod)&url=\(pathAndQuery)"
        } else {
            content = ""
        }

        let event = try signer.makeEvent(
            kind: EventKind(kind: 27235),
            tags: tags,
            content: content,
            keyPair: keyPair,
            createdAt: Date()
        )

        let json = try event.asJson()
        guard let data = json.data(using: .utf8) else {
            throw NIP98SignerError.jsonEncodingFailed
        }
        return "Nostr \(data.base64EncodedString())"
    }
}
