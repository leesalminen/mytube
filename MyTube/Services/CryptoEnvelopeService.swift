//
//  CryptoEnvelopeService.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import CryptoKit
import Foundation

enum CryptoEnvelopeError: Error {
    case algorithmUnavailable
    case encryptionFailed
    case decryptionFailed
    case wrappingFailed
    case unwrappingFailed
    case unsupported
}

struct MediaEncryptionSpec: Codable, Sendable {
    let algorithm: String
    let nonce: Data
}

struct WrappedKeyEnvelope: Codable, Sendable {
    let algorithm: String
    let ephemeralPublicKey: Data
    let wrapSalt: Data
    let wrapNonce: Data
    let keyCiphertext: Data
}

struct EncryptedMediaPayload: Sendable {
    let cipherText: Data
    let nonce: Data
    let tag: Data

    func combined() -> Data {
        nonce + cipherText + tag
    }
}

/// Provides helper utilities for XChaCha20-Poly1305 media encryption, key wrapping via X25519 + HKDF,
/// and NIP-44 message handling. Full algorithm implementations will be added in subsequent iterations;
/// for now these APIs establish the contract expected by higher layers.
final class CryptoEnvelopeService {
    func generateMediaKey() throws -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, 32, pointer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CryptoEnvelopeError.encryptionFailed
        }
        return key
    }

    func generateNonce(length: Int) throws -> Data {
        var nonce = Data(count: length)
        let status = nonce.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, length, pointer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CryptoEnvelopeError.encryptionFailed
        }
        return nonce
    }

    func encryptMedia(_ data: Data, key: Data) throws -> EncryptedMediaPayload {
        // Placeholder implementation using ChaChaPoly until XChaCha20-Poly1305 is integrated.
        // TODO: Replace with full XChaCha20-Poly1305 once the crypto backend is wired.
        guard key.count == 32 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }

        let symmetricKey = SymmetricKey(data: key)
        let nonceData = try generateNonce(length: 12)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let box = try ChaChaPoly.seal(data, using: symmetricKey, nonce: nonce)

        return EncryptedMediaPayload(
            cipherText: box.ciphertext,
            nonce: Data(nonce),
            tag: box.tag
        )
    }

    func decryptMedia(_ payload: EncryptedMediaPayload, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try ChaChaPoly.Nonce(data: payload.nonce)
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: payload.cipherText,
            tag: payload.tag
        )
        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }

    func wrapMediaKey(_ mediaKey: Data, for recipientPublicKey: Data) throws -> WrappedKeyEnvelope {
        // TODO: Implement X25519 + HKDF + ChaCha20-Poly1305 per spec.
        throw CryptoEnvelopeError.unsupported
    }

    func unwrapMediaKey(_ envelope: WrappedKeyEnvelope, with privateKey: Data) throws -> Data {
        // TODO: Implement X25519 + HKDF + ChaCha20-Poly1305 per spec.
        throw CryptoEnvelopeError.unsupported
    }

    func encryptDirectMessage(_ payload: Data, senderPrivateKey: Curve25519.Signing.PrivateKey, receiverPublicKey: Data) throws -> Data {
        // TODO: Implement NIP-44 compliant encryption.
        throw CryptoEnvelopeError.unsupported
    }

    func decryptDirectMessage(_ payload: Data, recipientPrivateKey: Curve25519.Signing.PrivateKey, senderPublicKey: Data) throws -> Data {
        // TODO: Implement NIP-44 compliant decryption.
        throw CryptoEnvelopeError.unsupported
    }
}
