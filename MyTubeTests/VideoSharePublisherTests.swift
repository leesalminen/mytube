//
//  VideoSharePublisherTests.swift
//  MyTubeTests
//
//  Created by Codex on 12/10/25.
//

import XCTest
import CryptoKit
import NostrSDK
@testable import MyTube

final class VideoSharePublisherTests: XCTestCase {
    private var tempURL: URL!
    private var storagePaths: StoragePaths!
    private var persistence: PersistenceController!
    private var parentProfileStore: ParentProfileStore!
    private var keyStore: KeychainKeyStore!
    private var cryptoService: CryptoEnvelopeService!
    private var storageClient: StubStorageClient!
    private var directMessageOutbox: StubDirectMessageOutbox!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSharePublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        storagePaths = try StoragePaths(baseURL: tempURL)
        persistence = PersistenceController(inMemory: true)
        parentProfileStore = ParentProfileStore(persistence: persistence)
        keyStore = KeychainKeyStore(service: "VideoSharePublisherTests.\(UUID().uuidString)")
        cryptoService = CryptoEnvelopeService()
        storageClient = StubStorageClient()
        directMessageOutbox = StubDirectMessageOutbox()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
        tempURL = nil
        try super.tearDownWithError()
    }

    func testShareWrapsMediaKeyWhenRecipientHasWrapKey() async throws {
        let publisher = VideoSharePublisher(
            storagePaths: storagePaths,
            cryptoService: cryptoService,
            storageClient: storageClient,
            directMessageOutbox: directMessageOutbox,
            keyStore: keyStore,
            parentProfileStore: parentProfileStore
        )

        let profileId = UUID()
        let video = try makeVideoModel(profileId: profileId)
        let remoteKeys = NostrSDK.Keys.generate()
        let recipientHex = remoteKeys.publicKey().toHex()

        let wrapKey = Curve25519.KeyAgreement.PrivateKey()
        _ = try parentProfileStore.upsertProfile(
            publicKey: recipientHex.lowercased(),
            name: "Remote Parent",
            displayName: nil,
            about: nil,
            pictureURLString: nil,
            wrapPublicKey: wrapKey.publicKey.rawRepresentation,
            updatedAt: Date()
        )

        _ = try await publisher.share(
            video: video,
            ownerChildNpub: "npub1childowner",
            recipientPublicKey: recipientHex
        )

        let dmPayload1 = try await directMessageOutbox.lastPayload()
        let decoded1 = try JSONDecoder().decode(VideoShareMessage.self, from: dmPayload1)
        XCTAssertNil(decoded1.crypto.mediaKey)
        XCTAssertEqual(decoded1.crypto.algWrap, cryptoService.wrapAlgorithmIdentifier)
        XCTAssertNotNil(decoded1.crypto.wrap)

        // Share to a second recipient with its own wrap key; uploads should be reused.
        let remoteKeysB = NostrSDK.Keys.generate()
        let recipientHexB = remoteKeysB.publicKey().toHex()
        let wrapKeyB = Curve25519.KeyAgreement.PrivateKey()
        _ = try parentProfileStore.upsertProfile(
            publicKey: recipientHexB.lowercased(),
            name: "Second Parent",
            displayName: nil,
            about: nil,
            pictureURLString: nil,
            wrapPublicKey: wrapKeyB.publicKey.rawRepresentation,
            updatedAt: Date()
        )

        _ = try await publisher.share(
            video: video,
            ownerChildNpub: "npub1childowner",
            recipientPublicKey: recipientHexB
        )

        let dmPayload2 = try await directMessageOutbox.lastPayload()
        let decoded2 = try JSONDecoder().decode(VideoShareMessage.self, from: dmPayload2)
        XCTAssertNil(decoded2.crypto.mediaKey)
        XCTAssertEqual(decoded2.crypto.algWrap, cryptoService.wrapAlgorithmIdentifier)
        XCTAssertNotNil(decoded2.crypto.wrap)

        let uploadCount = await storageClient.uploadInvocationCount()
        XCTAssertEqual(uploadCount, 2, "Expected a single media + thumbnail upload reused for both recipients.")

        let dmCount = await directMessageOutbox.payloadCount()
        XCTAssertEqual(dmCount, 2)
    }

    func testShareFallsBackToMediaKeyWithoutWrapKey() async throws {
        let publisher = VideoSharePublisher(
            storagePaths: storagePaths,
            cryptoService: cryptoService,
            storageClient: storageClient,
            directMessageOutbox: directMessageOutbox,
            keyStore: keyStore,
            parentProfileStore: parentProfileStore
        )

        let profileId = UUID()
        let video = try makeVideoModel(profileId: profileId)
        let remoteKeys = NostrSDK.Keys.generate()
        let recipientHex = remoteKeys.publicKey().toHex()

        let message = try await publisher.share(
            video: video,
            ownerChildNpub: "npub1childowner",
            recipientPublicKey: recipientHex
        )

        XCTAssertNotNil(message.crypto.mediaKey)
        XCTAssertNil(message.crypto.wrap)
    }

    private func makeVideoModel(profileId: UUID) throws -> VideoModel {
        try storagePaths.ensureProfileContainers(profileId: profileId)
        let videoPath = "Media/\(profileId.uuidString)/test.mp4"
        let thumbPath = "Thumbs/\(profileId.uuidString)/test.jpg"
        let videoURL = storagePaths.rootURL.appendingPathComponent(videoPath)
        let thumbURL = storagePaths.rootURL.appendingPathComponent(thumbPath)
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: videoURL)
        try Data([0x10, 0x11]).write(to: thumbURL)

        return VideoModel(
            id: UUID(),
            profileId: profileId,
            filePath: videoPath,
            thumbPath: thumbPath,
            title: "Sample Video",
            duration: 12,
            createdAt: Date(),
            lastPlayedAt: nil,
            playCount: 0,
            completionRate: 0,
            replayRate: 0,
            liked: false,
            hidden: false,
            tags: [],
            cvLabels: [],
            faceCount: 0,
            loudness: 0,
            reportedAt: nil,
            reportReason: nil
        )
    }
}

actor StubStorageClient: MediaStorageClient {
    private(set) var stored: [String: Data] = [:]
    private var uploadCount: Int = 0

    func uploadObject(
        data: Data,
        contentType: String,
        suggestedKey: String?
    ) async throws -> StorageUploadResult {
        uploadCount += 1
        let key = suggestedKey ?? UUID().uuidString
        stored[key] = data
        return StorageUploadResult(key: key, accessURL: URL(string: "https://example.com/\(key)")!)
    }

    func objectURL(for key: String) async throws -> URL {
        URL(string: "https://example.com/\(key)")!
    }

    func downloadObject(key: String, fallbackURL: URL?) async throws -> Data {
        if let data = stored[key] {
            return data
        }
        throw NSError(domain: "StubStorageClient", code: 0)
    }

    func uploadInvocationCount() async -> Int {
        uploadCount
    }
}

actor StubDirectMessageOutbox: DirectMessageSending {
    private let encoder = JSONEncoder()
    private var payloads: [Data] = []
    private let signer = NostrEventSigner()

    enum Error: Swift.Error {
        case noPayload
    }

    @discardableResult
    func sendMessage<Payload>(
        _ message: Payload,
        kind: DirectMessageKind,
        recipientPublicKey: String,
        additionalTags: [Tag],
        relayOverride: [URL]?,
        createdAt: Date
    ) async throws -> NostrEvent where Payload: Encodable {
        let data = try encoder.encode(message)
        payloads.append(data)

        let secret = NostrSDK.SecretKey.generate()
        let keyPair = try NostrKeyPair(secretKey: secret)
        return try signer.makeEvent(
            kind: .directMessage,
            tags: [],
            content: "stub",
            keyPair: keyPair,
            createdAt: createdAt
        )
    }

    func lastPayload() async throws -> Data {
        guard let data = payloads.last else {
            throw Error.noPayload
        }
        return data
    }

    func payloadCount() async -> Int {
        payloads.count
    }
}
