//
//  MarmotShareServiceTests.swift
//  MyTubeTests
//
//  Created by Assistant on 03/01/26.
//

import XCTest
import NostrSDK
@testable import MyTube

final class MarmotShareServiceTests: XCTestCase {
    func testPublishVideoShareEncodesPayloadAndPublishes() async throws {
        let mdkActor = StubMessageMdkActor()
        let transport = StubMessagePublisher()
        let keyStore = KeychainKeyStore(service: "MarmotShareServiceTests.\(UUID().uuidString)")
        _ = try keyStore.ensureParentKeyPair()

        let service = MarmotShareService(
            mdkActor: mdkActor,
            transport: transport,
            keyStore: keyStore
        )

        let message = makeVideoShareMessage()
        let result = try await service.publishVideoShare(message: message, mlsGroupId: "group123")

        XCTAssertEqual(result.groupId, "group123")
        let recorded = await mdkActor.recordedCalls
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.mlsGroupId, "group123")
        XCTAssertEqual(recorded.first?.kind, MarmotMessageKind.videoShare.rawValue)

        let published = await transport.publishedPayloads
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.groupId, "group123")
    }

    func testPublishVideoShareRequiresParentIdentity() async throws {
        let mdkActor = StubMessageMdkActor()
        let transport = StubMessagePublisher()
        let keyStore = KeychainKeyStore(service: "MarmotShareServiceTests.\(UUID().uuidString)")
        let service = MarmotShareService(
            mdkActor: mdkActor,
            transport: transport,
            keyStore: keyStore
        )

        do {
            _ = try await service.publishVideoShare(message: makeVideoShareMessage(), mlsGroupId: "group123")
            XCTFail("Expected parentIdentityMissing error")
        } catch {
            guard case MarmotShareService.ShareError.parentIdentityMissing = error else {
                return XCTFail("Expected parentIdentityMissing, got \(error)")
            }
        }
    }

    func testPublishVideoRevokeUsesLifecycleKind() async throws {
        let setup = try makeService()
        let message = VideoLifecycleMessage(
            kind: .videoRevoke,
            videoId: "video123",
            reason: "oops",
            by: "parenthex",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        _ = try await setup.service.publishVideoRevoke(message: message, mlsGroupId: "group123")

        let recorded = await setup.mdk.recordedCalls
        XCTAssertEqual(recorded.last?.kind, MarmotMessageKind.videoRevoke.rawValue)
    }

    func testPublishLikeUsesLikeKind() async throws {
        let setup = try makeService()
        let message = LikeMessage(
            videoId: "video123",
            viewerChild: "npubchild",
            by: "parenthex",
            timestamp: Date(timeIntervalSince1970: 456)
        )
        _ = try await setup.service.publishLike(message: message, mlsGroupId: "group123")

        let recorded = await setup.mdk.recordedCalls
        XCTAssertEqual(recorded.last?.kind, MarmotMessageKind.like.rawValue)
    }

    func testPublishReportUsesReportKind() async throws {
        let setup = try makeService()
        let message = ReportMessage(
            videoId: "video123",
            subjectChild: "npubchild",
            reason: "spam",
            note: "notes",
            by: "parenthex",
            timestamp: Date(timeIntervalSince1970: 789)
        )
        _ = try await setup.service.publishReport(message: message, mlsGroupId: "group123")

        let recorded = await setup.mdk.recordedCalls
        XCTAssertEqual(recorded.last?.kind, MarmotMessageKind.report.rawValue)
    }

    private func makeVideoShareMessage() -> VideoShareMessage {
        let blob = VideoShareMessage.Blob(
            url: "https://example.com/media.bin",
            mime: "video/mp4",
            length: 128,
            key: "media.bin"
        )
        let thumb = VideoShareMessage.Blob(
            url: "https://example.com/thumb.jpg",
            mime: "image/jpeg",
            length: 16,
            key: "thumb.jpg"
        )
        let crypto = VideoShareMessage.Crypto(
            algMedia: "xchacha20",
            nonceMedia: "nonce",
            mediaKey: "mediakey"
        )
        return VideoShareMessage(
            videoId: UUID().uuidString,
            ownerChild: "npub1child",
            meta: nil,
            blob: blob,
            thumb: thumb,
            crypto: crypto,
            policy: nil,
            by: "parenthex",
            timestamp: Date()
        )
    }

    private func makeService() throws -> (
        service: MarmotShareService,
        mdk: StubMessageMdkActor,
        transport: StubMessagePublisher
    ) {
        let mdkActor = StubMessageMdkActor()
        let transport = StubMessagePublisher()
        let keyStore = KeychainKeyStore(service: "MarmotShareServiceTests.\(UUID().uuidString)")
        _ = try keyStore.ensureParentKeyPair()
        let service = MarmotShareService(
            mdkActor: mdkActor,
            transport: transport,
            keyStore: keyStore
        )
        return (service, mdkActor, transport)
    }
}

// MARK: - Test doubles

private actor StubMessageMdkActor: MarmotMessageProducing {
    struct CallRecord {
        let mlsGroupId: String
        let senderPublicKey: String
        let content: String
        let kind: UInt16
    }

    private(set) var recordedCalls: [CallRecord] = []
    var responseJson: String = #"{"id":"event123"}"#

    func createMessage(
        mlsGroupId: String,
        senderPublicKey: String,
        content: String,
        kind: UInt16
    ) throws -> String {
        recordedCalls.append(
            CallRecord(
                mlsGroupId: mlsGroupId,
                senderPublicKey: senderPublicKey,
                content: content,
                kind: kind
            )
        )
        return responseJson
    }
}

private actor StubMessagePublisher: MarmotMessagePublishing {
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
