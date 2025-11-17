//
//  VideoSharePublisherTests.swift
//  MyTubeTests
//
//  Created by Codex on 12/10/25.
//

import XCTest
@testable import MyTube

final class VideoSharePublisherTests: XCTestCase {
    private var tempURL: URL!
    private var storagePaths: StoragePaths!
    private var persistence: PersistenceController!
    private var keyStore: KeychainKeyStore!
    private var cryptoService: CryptoEnvelopeService!
    private var storageClient: StubStorageClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSharePublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        storagePaths = try StoragePaths(baseURL: tempURL)
        persistence = PersistenceController(inMemory: true)
        keyStore = KeychainKeyStore(service: "VideoSharePublisherTests.\(UUID().uuidString)")
        cryptoService = CryptoEnvelopeService()
        storageClient = StubStorageClient()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
        tempURL = nil
        try super.tearDownWithError()
    }

    func testMakeShareMessageEmbedsMediaKey() async throws {
        let publisher = VideoSharePublisher(
            storagePaths: storagePaths,
            cryptoService: cryptoService,
            storageClient: storageClient,
            keyStore: keyStore
        )

        let profileId = UUID()
        let video = try makeVideoModel(profileId: profileId)
        _ = try keyStore.ensureParentKeyPair()

        let message = try await publisher.makeShareMessage(
            video: video,
            ownerChildNpub: "npub1childowner"
        )

        XCTAssertNotNil(message.crypto.mediaKey)
        XCTAssertNil(message.crypto.wrap)
        XCTAssertEqual(message.crypto.algMedia, cryptoService.mediaAlgorithmIdentifier)
    }

    func testMakeShareMessageReusesUploadsForSameVideo() async throws {
        let publisher = VideoSharePublisher(
            storagePaths: storagePaths,
            cryptoService: cryptoService,
            storageClient: storageClient,
            keyStore: keyStore
        )

        let profileId = UUID()
        let video = try makeVideoModel(profileId: profileId)
        _ = try keyStore.ensureParentKeyPair()

        let first = try await publisher.makeShareMessage(
            video: video,
            ownerChildNpub: "npub1childowner"
        )

        let second = try await publisher.makeShareMessage(
            video: video,
            ownerChildNpub: "npub1childowner"
        )

        let uploadCount = await storageClient.uploadInvocationCount()
        XCTAssertEqual(uploadCount, 2, "Expected a single media and thumbnail upload reused across shares.")
        XCTAssertEqual(first.blob.url, second.blob.url)
        XCTAssertEqual(first.thumb.url, second.thumb.url)
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
