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
/// and NIP-44 message handling.
final class CryptoEnvelopeService {
    private enum Constants {
        static let mediaAlgorithm = "xchacha20poly1305_v1"
        static let wrapAlgorithm = "x25519-hkdf-chacha20poly1305_v1"
        static let wrapInfo = Data("mytube:wrap:Vk:v1".utf8)
        static let dmInfo = Data("mytube:nip44:v1".utf8)
        static let dmSalt = Data()
        static let dmVersion: UInt8 = 1
        static let chachaTagLength = 16
        static let xchachaNonceLength = 24
        static let wrapSaltLength = 32
        static let wrapNonceLength = 12
    }

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
        guard key.count == 32 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }
        let nonce = try generateNonce(length: Constants.xchachaNonceLength)
        let sealed = try XChaCha20Poly1305.seal(
            message: data,
            key: key,
            nonce: nonce,
            authenticatedData: nil
        )
        return EncryptedMediaPayload(
            cipherText: sealed.ciphertext,
            nonce: nonce,
            tag: sealed.tag
        )
    }

    func decryptMedia(_ payload: EncryptedMediaPayload, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }
        guard payload.nonce.count == Constants.xchachaNonceLength else {
            throw CryptoEnvelopeError.decryptionFailed
        }
        return try XChaCha20Poly1305.open(
            ciphertext: payload.cipherText,
            tag: payload.tag,
            key: key,
            nonce: payload.nonce,
            authenticatedData: nil
        )
    }

    func wrapMediaKey(_ mediaKey: Data, for recipientPublicKey: Data) throws -> WrappedKeyEnvelope {
        guard mediaKey.count == 32 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }

        let recipientPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPublic)
        let salt = try generateNonce(length: Constants.wrapSaltLength)
        let wrapKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Constants.wrapInfo,
            outputByteCount: 32
        )

        let nonceData = try generateNonce(length: Constants.wrapNonceLength)
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(mediaKey, using: wrapKey, nonce: nonce)
        let combined = sealed.ciphertext + sealed.tag

        return WrappedKeyEnvelope(
            algorithm: Constants.wrapAlgorithm,
            ephemeralPublicKey: ephemeralPrivate.publicKey.rawRepresentation,
            wrapSalt: salt,
            wrapNonce: nonceData,
            keyCiphertext: combined
        )
    }

    func unwrapMediaKey(_ envelope: WrappedKeyEnvelope, with privateKey: Data) throws -> Data {
        guard envelope.algorithm == Constants.wrapAlgorithm else {
            throw CryptoEnvelopeError.unsupported
        }

        guard envelope.keyCiphertext.count >= Constants.chachaTagLength else {
            throw CryptoEnvelopeError.decryptionFailed
        }

        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let ephemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)

        let wrapKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: envelope.wrapSalt,
            sharedInfo: Constants.wrapInfo,
            outputByteCount: 32
        )

        let nonce = try ChaChaPoly.Nonce(data: envelope.wrapNonce)
        let tagStart = envelope.keyCiphertext.count - Constants.chachaTagLength
        let ciphertext = envelope.keyCiphertext.prefix(tagStart)
        let tag = envelope.keyCiphertext.suffix(Constants.chachaTagLength)

        let sealed = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        return try ChaChaPoly.open(sealed, using: wrapKey)
    }

    func encryptDirectMessage(
        _ payload: Data,
        senderPrivateKey: Curve25519.Signing.PrivateKey,
        receiverPublicKey: Data
    ) throws -> Data {
        let sharedKey = try deriveSharedSecret(
            privateKeyData: senderPrivateKey.rawRepresentation,
            peerPublicKeyData: receiverPublicKey
        )

        let nonce = try generateNonce(length: Constants.xchachaNonceLength)
        let sealed = try XChaCha20Poly1305.seal(
            message: payload,
            key: sharedKey,
            nonce: nonce,
            authenticatedData: nil
        )

        var frame = Data(capacity: 1 + nonce.count + sealed.ciphertext.count + sealed.tag.count)
        frame.append(Constants.dmVersion)
        frame.append(nonce)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        return frame
    }

    func decryptDirectMessage(
        _ payload: Data,
        recipientPrivateKey: Curve25519.Signing.PrivateKey,
        senderPublicKey: Data
    ) throws -> Data {
        guard payload.count > 1 + Constants.xchachaNonceLength + Constants.chachaTagLength else {
            throw CryptoEnvelopeError.decryptionFailed
        }
        guard payload.first == Constants.dmVersion else {
            throw CryptoEnvelopeError.decryptionFailed
        }

        let nonceRange = 1 ..< (1 + Constants.xchachaNonceLength)
        let nonce = payload[nonceRange]

        let ciphertextAndTag = payload[(1 + Constants.xchachaNonceLength)...]
        guard ciphertextAndTag.count >= Constants.chachaTagLength else {
            throw CryptoEnvelopeError.decryptionFailed
        }
        let tagStart = ciphertextAndTag.count - Constants.chachaTagLength
        let ciphertext = ciphertextAndTag.prefix(tagStart)
        let tag = ciphertextAndTag.suffix(Constants.chachaTagLength)

        let sharedKey = try deriveSharedSecret(
            privateKeyData: recipientPrivateKey.rawRepresentation,
            peerPublicKeyData: senderPublicKey
        )

        return try XChaCha20Poly1305.open(
            ciphertext: ciphertext,
            tag: tag,
            key: sharedKey,
            nonce: Data(nonce),
            authenticatedData: nil
        )
    }

    private func deriveSharedSecret(privateKeyData: Data, peerPublicKeyData: Data) throws -> Data {
        let privateRaw: Data
        switch privateKeyData.count {
        case 32:
            privateRaw = privateKeyData
        case 64:
            privateRaw = privateKeyData.prefix(32)
        default:
            throw CryptoEnvelopeError.algorithmUnavailable
        }

        let agreementPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateRaw)
        let agreementPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
        let sharedSecret = try agreementPrivate.sharedSecretFromKeyAgreement(with: agreementPublic)
        let symmetric = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Constants.dmSalt,
            sharedInfo: Constants.dmInfo,
            outputByteCount: 32
        )
        return symmetric.withUnsafeBytes { Data($0) }
    }
}

// MARK: - XChaCha20-Poly1305 Helper

private enum XChaCha20Poly1305 {
    static func seal(
        message: Data,
        key: Data,
        nonce: Data,
        authenticatedData: Data?
    ) throws -> (ciphertext: Data, tag: Data) {
        let (subKey, derivedNonce) = try deriveKeyAndNonce(key: key, nonce: nonce)
        let symmetricKey = SymmetricKey(data: subKey)
        let chachaNonce = try ChaChaPoly.Nonce(data: derivedNonce)

        let sealed: ChaChaPoly.SealedBox
        if let authenticatedData {
            sealed = try ChaChaPoly.seal(message, using: symmetricKey, nonce: chachaNonce, authenticating: authenticatedData)
        } else {
            sealed = try ChaChaPoly.seal(message, using: symmetricKey, nonce: chachaNonce)
        }
        return (sealed.ciphertext, sealed.tag)
    }

    static func open(
        ciphertext: Data,
        tag: Data,
        key: Data,
        nonce: Data,
        authenticatedData: Data?
    ) throws -> Data {
        let (subKey, derivedNonce) = try deriveKeyAndNonce(key: key, nonce: nonce)
        let symmetricKey = SymmetricKey(data: subKey)
        let chachaNonce = try ChaChaPoly.Nonce(data: derivedNonce)

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chachaNonce,
            ciphertext: ciphertext,
            tag: tag
        )
        if let authenticatedData {
            return try ChaChaPoly.open(sealedBox, using: symmetricKey, authenticating: authenticatedData)
        } else {
            return try ChaChaPoly.open(sealedBox, using: symmetricKey)
        }
    }

    private static func deriveKeyAndNonce(key: Data, nonce: Data) throws -> (key: Data, nonce: Data) {
        guard key.count == 32 else { throw CryptoEnvelopeError.algorithmUnavailable }
        guard nonce.count == 24 else { throw CryptoEnvelopeError.algorithmUnavailable }

        let nonce16 = nonce.prefix(16)
        let nonceTail = nonce.suffix(8)

        let subKey = try hChaCha20(key: key, nonce: nonce16)
        var derivedNonce = Data([0, 0, 0, 0])
        derivedNonce.append(nonceTail)
        return (subKey, derivedNonce)
    }

    private static func hChaCha20(key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 16 else {
            throw CryptoEnvelopeError.algorithmUnavailable
        }

        var state: [UInt32] = [
            0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574
        ]
        state.append(contentsOf: key.wordsLittleEndian(count: 8))
        state.append(contentsOf: nonce.wordsLittleEndian(count: 4))

        state.withUnsafeMutableBufferPointer { buffer in
            for _ in 0..<10 {
                // Column rounds
                quarterRound(&buffer[0], &buffer[4], &buffer[8], &buffer[12])
                quarterRound(&buffer[1], &buffer[5], &buffer[9], &buffer[13])
                quarterRound(&buffer[2], &buffer[6], &buffer[10], &buffer[14])
                quarterRound(&buffer[3], &buffer[7], &buffer[11], &buffer[15])

                // Diagonal rounds
                quarterRound(&buffer[0], &buffer[5], &buffer[10], &buffer[15])
                quarterRound(&buffer[1], &buffer[6], &buffer[11], &buffer[12])
                quarterRound(&buffer[2], &buffer[7], &buffer[8], &buffer[13])
                quarterRound(&buffer[3], &buffer[4], &buffer[9], &buffer[14])
            }
        }

        var output = Data(count: 32)
        let words: [UInt32] = [
            state[0], state[1], state[2], state[3],
            state[12], state[13], state[14], state[15]
        ]
        for (index, word) in words.enumerated() {
            let offset = index * 4
            output.replaceSubrange(offset ..< offset + 4, with: word.littleEndianBytes)
        }
        return output
    }

    @inline(__always)
    private static func quarterRound(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32) {
        a = a &+ b; d ^= a; d = d.rotatedLeft(by: 16)
        c = c &+ d; b ^= c; b = b.rotatedLeft(by: 12)
        a = a &+ b; d ^= a; d = d.rotatedLeft(by: 8)
        c = c &+ d; b ^= c; b = b.rotatedLeft(by: 7)
    }
}

// MARK: - Data Helpers

private extension Data {
    func wordsLittleEndian(count: Int) -> [UInt32] {
        precondition(self.count >= count * 4)
        var result: [UInt32] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let start = self.index(self.startIndex, offsetBy: index * 4)
            let end = self.index(start, offsetBy: 4)
            let slice = self[start..<end]
            let value = slice.withUnsafeBytes { raw -> UInt32 in
                raw.load(as: UInt32.self)
            }
            result.append(UInt32(littleEndian: value))
        }
        return result
    }
}

private extension UInt32 {
    @inline(__always)
    func rotatedLeft(by n: UInt32) -> UInt32 {
        (self << n) | (self >> (32 - n))
    }

    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return withUnsafeBytes(of: value) { Array($0) }
    }
}
