//
//  CryptoEnvelopeServiceTests.swift
//  MyTubeTests
//
//  Created by Codex on 10/30/25.
//

import CryptoKit
import Foundation
import Testing
@testable import MyTube

struct CryptoEnvelopeServiceTests {
    private let service = CryptoEnvelopeService()

    @Test("XChaCha20 media encryption round-trips")
    func mediaEncryptionRoundTrip() throws {
        let key = try service.generateMediaKey()
        #expect(key.count == 32)

        let message = Data("Private playground secrets".utf8)
        let payload = try service.encryptMedia(message, key: key)

        #expect(payload.nonce.count == 24)
        #expect(payload.tag.count == 16)
        let decrypted = try service.decryptMedia(payload, key: key)
        #expect(decrypted == message)
    }

    @Test("Media key wrap/unwrap with X25519 succeeds")
    func keyWrapRoundTrip() throws {
        let mediaKey = try service.generateMediaKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()

        let envelope = try service.wrapMediaKey(mediaKey, for: recipient.publicKey.rawRepresentation)
        #expect(envelope.algorithm == "x25519-hkdf-chacha20poly1305_v1")
        #expect(envelope.ephemeralPublicKey.count == 32)
        #expect(envelope.wrapSalt.count == 32)
        #expect(envelope.wrapNonce.count == 12)

        let recovered = try service.unwrapMediaKey(envelope, with: recipient.rawRepresentation)
        #expect(recovered == mediaKey)

        let unexpectedRecipient = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: Error.self) {
            _ = try service.unwrapMediaKey(envelope, with: unexpectedRecipient.rawRepresentation)
        }
    }

    @Test("NIP-44 direct messages decrypt with matching keys")
    func directMessageRoundTrip() throws {
        let sender = try service.generateSigningKeyPair()
        let recipient = try service.generateSigningKeyPair()
        let plaintext = Data("Let's build rockets!".utf8)

        let encrypted = try service.encryptDirectMessage(
            plaintext,
            senderPrivateKeyData: sender.privateKey,
            recipientPublicKeyXOnly: recipient.publicKeyXOnly
        )

        let decoded = try #require(Data(base64Encoded: encrypted))
        #expect(decoded.first == 0x02)

        let decrypted = try service.decryptDirectMessage(
            encrypted,
            recipientPrivateKeyData: recipient.privateKey,
            senderPublicKeyXOnly: sender.publicKeyXOnly
        )
        #expect(decrypted == plaintext)

        let encryptedAgain = try service.encryptDirectMessage(
            plaintext,
            senderPrivateKeyData: sender.privateKey,
            recipientPublicKeyXOnly: recipient.publicKeyXOnly
        )
        #expect(encryptedAgain != encrypted)
    }
}
