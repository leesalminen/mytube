import Foundation
@testable import MyTube
import NostrSDK
import Testing

struct NIP44EncryptionTests {
    private let service = CryptoEnvelopeService()

    private let senderPrivateHex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let recipientPrivateHex = "2222222222222222222222222222222222222222222222222222222222222222"

    @Test("NIP-44 ciphertext decrypts with matching keys")
    func nip44RoundTripWithStaticKeys() throws {
        let senderData = try #require(Data(hexString: senderPrivateHex))
        let recipientData = try #require(Data(hexString: recipientPrivateHex))

        let senderSecret = try SecretKey.fromBytes(bytes: senderData)
        let recipientSecret = try SecretKey.fromBytes(bytes: recipientData)

        let senderKeys = Keys(secretKey: senderSecret)
        let recipientKeys = Keys(secretKey: recipientSecret)
        let recipientPublic = recipientKeys.publicKey()
        let senderPublic = senderKeys.publicKey()

        let plaintext = Data("Follow approval handshake".utf8)

        let ciphertext = try service.encryptDirectMessage(
            plaintext,
            senderPrivateKeyData: senderData,
            recipientPublicKeyXOnly: try #require(Data(hexString: recipientPublic.toHex()))
        )

        let decrypted = try service.decryptDirectMessage(
            ciphertext,
            recipientPrivateKeyData: recipientData,
            senderPublicKeyXOnly: try #require(Data(hexString: senderPublic.toHex()))
        )

        #expect(decrypted == plaintext)
    }

    @Test("Service decrypts payloads produced by rust-nostr nip44Encrypt")
    func decryptsRustNostrCiphertext() throws {
        let senderData = try #require(Data(hexString: senderPrivateHex))
        let recipientData = try #require(Data(hexString: recipientPrivateHex))

        let senderSecret = try SecretKey.fromBytes(bytes: senderData)
        let recipientSecret = try SecretKey.fromBytes(bytes: recipientData)

        let senderKeys = Keys(secretKey: senderSecret)
        let recipientKeys = Keys(secretKey: recipientSecret)
        let recipientPublic = recipientKeys.publicKey()
        let senderPublic = senderKeys.publicKey()

        let plaintext = "NIP-44 deterministic test"
        let ciphertext = try nip44Encrypt(
            secretKey: senderSecret,
            publicKey: recipientPublic,
            content: plaintext,
            version: .v2
        )

        let decrypted = try service.decryptDirectMessage(
            ciphertext,
            recipientPrivateKeyData: recipientData,
            senderPublicKeyXOnly: try #require(Data(hexString: senderPublic.toHex()))
        )

        #expect(String(data: decrypted, encoding: .utf8) == plaintext)
    }
}
