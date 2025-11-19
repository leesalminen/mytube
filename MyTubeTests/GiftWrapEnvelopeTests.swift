import Foundation
@testable import MyTube
import NostrSDK
import Testing

struct GiftWrapEnvelopeTests {
    private let service = CryptoEnvelopeService()

    private let senderPrivateHex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let recipientPrivateHex = "2222222222222222222222222222222222222222222222222222222222222222"

    @Test("Gift-wrap envelope decrypts with matching keys")
    func giftWrapRoundTripWithStaticKeys() throws {
        let senderData = try #require(Data(hexString: senderPrivateHex))
        let recipientData = try #require(Data(hexString: recipientPrivateHex))

        let senderSecret = try SecretKey.fromBytes(bytes: senderData)
        let recipientSecret = try SecretKey.fromBytes(bytes: recipientData)

        let senderKeys = Keys(secretKey: senderSecret)
        let recipientKeys = Keys(secretKey: recipientSecret)
        let recipientPublic = recipientKeys.publicKey()
        let senderPublic = senderKeys.publicKey()

        let plaintext = Data("Follow approval handshake".utf8)

        let ciphertext = try service.encryptGiftWrapEnvelope(
            plaintext,
            senderPrivateKeyData: senderData,
            recipientPublicKeyXOnly: try #require(Data(hexString: recipientPublic.toHex()))
        )

        let decrypted = try service.decryptGiftWrapEnvelope(
            ciphertext,
            recipientPrivateKeyData: recipientData,
            senderPublicKeyXOnly: try #require(Data(hexString: senderPublic.toHex()))
        )

        #expect(decrypted == plaintext)
    }

    @Test("Service decrypts envelopes produced by rust-nostr gift-wrap helper")
    func decryptsRustNostrCiphertext() throws {
        let senderData = try #require(Data(hexString: senderPrivateHex))
        let recipientData = try #require(Data(hexString: recipientPrivateHex))

        let senderSecret = try SecretKey.fromBytes(bytes: senderData)
        let recipientSecret = try SecretKey.fromBytes(bytes: recipientData)

        let senderKeys = Keys(secretKey: senderSecret)
        let recipientKeys = Keys(secretKey: recipientSecret)
        let recipientPublic = recipientKeys.publicKey()
        let senderPublic = senderKeys.publicKey()

        let plaintext = "Gift wrap deterministic test"
        let ciphertext = try nip44Encrypt(
            secretKey: senderSecret,
            publicKey: recipientPublic,
            content: plaintext,
            version: .v2
        )

        let decrypted = try service.decryptGiftWrapEnvelope(
            ciphertext,
            recipientPrivateKeyData: recipientData,
            senderPublicKeyXOnly: try #require(Data(hexString: senderPublic.toHex()))
        )

        #expect(String(data: decrypted, encoding: .utf8) == plaintext)
    }
}
