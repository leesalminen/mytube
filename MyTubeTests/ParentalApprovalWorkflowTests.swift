//
//  ParentalApprovalWorkflowTests.swift
//  MyTubeTests
//
//  Created by Assistant on 02/18/26.
//

import Foundation
import NostrSDK
import XCTest
@testable import MyTube

@MainActor
final class ParentalApprovalWorkflowTests: XCTestCase {
    func testPendingVideoRequiresParentPublish() async throws {
        let harness = try makeHarness()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: harness.rootURL)
        }

        harness.parentalControlsStore.setRequiresVideoApproval(true)
        harness.parentalControlsStore.setEnableContentScanning(false)

        let tempVideo = harness.rootURL.appendingPathComponent("source-\(UUID().uuidString).mp4")
        let tempThumb = harness.rootURL.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
        try Data([0x0, 0x1, 0x2]).write(to: tempVideo)
        try Data([0x3, 0x4]).write(to: tempThumb)

        let request = VideoCreationRequest(
            profileId: harness.profileId,
            sourceURL: tempVideo,
            thumbnailURL: tempThumb,
            title: "Pending Clip",
            duration: 6,
            tags: [],
            cvLabels: [],
            faceCount: 0,
            loudness: 0.1
        )

        let video = try await harness.videoLibrary.createVideo(request: request)
        XCTAssertEqual(video.approvalStatus, .pending)

        // Allow coordinator to observe initial save and skip share while pending.
        try await Task.sleep(nanoseconds: 150_000_000)
        let initialPublishes = await harness.messagePublisher.publishedPayloads.count
        XCTAssertEqual(initialPublishes, 0)

        let publishExpectation = expectation(description: "Publish after approval")
        Task {
            while await harness.messagePublisher.publishedPayloads.count < 1 {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            publishExpectation.fulfill()
        }

        try await harness.shareCoordinator.publishVideo(video.id)

        wait(for: [publishExpectation], timeout: 2.0)

        let published = await harness.messagePublisher.publishedPayloads
        XCTAssertEqual(published.count, 1)

        let fetchRequest = VideoEntity.fetchRequest()
        let storedVideos = try harness.persistence.viewContext.fetch(fetchRequest)
        guard let stored = storedVideos.first(where: { $0.id == video.id }) else {
            return XCTFail("Expected stored video")
        }

        XCTAssertEqual(stored.approvalStatus, VideoModel.ApprovalStatus.approved.rawValue)
        XCTAssertEqual(stored.approvedByParentKey?.lowercased(), harness.parentKey.lowercased())
        XCTAssertNotNil(stored.approvedAt)
    }
}

// MARK: - Harness

@MainActor
private func makeHarness() throws -> (
    persistence: PersistenceController,
    storagePaths: StoragePaths,
    parentalControlsStore: ParentalControlsStore,
    videoLibrary: VideoLibrary,
    shareCoordinator: VideoShareCoordinator,
    messagePublisher: ApprovalStubMessagePublisher,
    profileId: UUID,
    parentKey: String,
    rootURL: URL
) {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("ParentalApprovalWorkflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let storagePaths = try StoragePaths(baseURL: rootURL)
    let persistence = PersistenceController(inMemory: true)
    let defaultsSuite = "ParentalApprovalWorkflowTests.\(UUID().uuidString)"
    let parentalDefaults = UserDefaults(suiteName: defaultsSuite)!
    parentalDefaults.removePersistentDomain(forName: defaultsSuite)
    let parentalControlsStore = ParentalControlsStore(userDefaults: parentalDefaults)
    let videoLibrary = VideoLibrary(
        persistence: persistence,
        storagePaths: storagePaths,
        parentalControlsStore: parentalControlsStore,
        contentScanner: VideoContentScanner()
    )

    let keyStore = KeychainKeyStore(service: "ParentalApprovalWorkflowTests.\(UUID().uuidString)")
    let parentPair = try keyStore.ensureParentKeyPair()
    let cryptoService = CryptoEnvelopeService()
    let storageClient = StubStorageClient()
    let videoSharePublisher = VideoSharePublisher(
        storagePaths: storagePaths,
        cryptoService: cryptoService,
        storageClient: storageClient,
        keyStore: keyStore
    )
    let mdkActor = ApprovalStubMessageMdkActor()
    let messagePublisher = ApprovalStubMessagePublisher()
    let marmotShareService = MarmotShareService(
        mdkActor: mdkActor,
        transport: messagePublisher,
        keyStore: keyStore
    )
    let shareCoordinator = VideoShareCoordinator(
        persistence: persistence,
        keyStore: keyStore,
        videoSharePublisher: videoSharePublisher,
        marmotShareService: marmotShareService,
        parentalControlsStore: parentalControlsStore
    )

    // Seed a profile with a group for sharing.
    let profile = ProfileEntity(context: persistence.viewContext)
    let profileId = UUID()
    profile.id = profileId
    profile.name = "Child"
    profile.theme = ThemeDescriptor.ocean.rawValue
    profile.avatarAsset = ThemeDescriptor.ocean.defaultAvatarAsset
    profile.mlsGroupId = "group-\(UUID().uuidString)"
    try persistence.viewContext.save()

    return (
        persistence,
        storagePaths,
        parentalControlsStore,
        videoLibrary,
        shareCoordinator,
        messagePublisher,
        profileId,
        parentPair.publicKeyHex.lowercased(),
        rootURL
    )
}

// MARK: - Stubs

actor ApprovalStubMessageMdkActor: MarmotMessageProducing {
    func createMessage(
        mlsGroupId: String,
        senderPublicKey: String,
        content: String,
        kind: UInt16
    ) throws -> String {
        #"{"id":"event123","group":"\#(mlsGroupId)"}"#
    }
}

actor ApprovalStubMessagePublisher: MarmotMessagePublishing {
    private(set) var publishedPayloads: [(groupId: String, json: String, relayOverride: [URL]?)] = []
    private let signer = NostrEventSigner()

    func publishMessage(
        mlsGroupId: String,
        eventJson: String,
        relayOverride: [URL]? = nil
    ) async throws -> NostrEvent {
        publishedPayloads.append((mlsGroupId, eventJson, relayOverride))
        let keyPair = try NostrKeyPair(secretKey: SecretKey.generate())
        return try signer.makeEvent(
            kind: Kind(kind: 1),
            tags: [],
            content: "{}",
            keyPair: keyPair,
            createdAt: Date()
        )
    }
}
