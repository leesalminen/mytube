//
//  RemoteVideoStoreTests.swift
//  MyTubeTests
//
//  Created by Assistant on 03/05/26.
//

import CoreData
import XCTest
@testable import MyTube

final class RemoteVideoStoreTests: XCTestCase {
    func testShareSummariesAggregateByOwner() throws {
        let persistence = PersistenceController(inMemory: true)
        let store = RemoteVideoStore(persistence: persistence)
        let ownerA = String(repeating: "a", count: 64)
        let ownerB = "npub1exampleownerb"
        let now = Date()

        try insertVideo(
            context: persistence.viewContext,
            owner: ownerA,
            status: .available,
            createdAt: now
        )
        try insertVideo(
            context: persistence.viewContext,
            owner: ownerA,
            status: .revoked,
            createdAt: now.addingTimeInterval(-120)
        )
        try insertVideo(
            context: persistence.viewContext,
            owner: ownerA,
            status: .available,
            createdAt: now.addingTimeInterval(-60)
        )
        try insertVideo(
            context: persistence.viewContext,
            owner: ownerB,
            status: .blocked,
            createdAt: now.addingTimeInterval(-30)
        )
        try insertVideo(
            context: persistence.viewContext,
            owner: ownerB,
            status: .deleted,
            createdAt: now.addingTimeInterval(-15)
        )

        let summaries = try store.shareSummaries()
        XCTAssertEqual(summaries.count, 2)

        let mapping = Dictionary(uniqueKeysWithValues: summaries.map { ($0.ownerChild, $0) })

        guard let summaryA = mapping[ownerA] else {
            return XCTFail("Expected summary for owner A")
        }
        XCTAssertEqual(summaryA.availableCount, 2)
        XCTAssertEqual(summaryA.revokedCount, 1)
        XCTAssertEqual(summaryA.blockedCount, 0)
        XCTAssertEqual(summaryA.deletedCount, 0)
        XCTAssertEqual(summaryA.lastSharedAt?.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.5)

        guard let summaryB = mapping[ownerB] else {
            return XCTFail("Expected summary for owner B")
        }
        XCTAssertEqual(summaryB.availableCount, 0)
        XCTAssertEqual(summaryB.revokedCount, 0)
        XCTAssertEqual(summaryB.blockedCount, 1)
        XCTAssertEqual(summaryB.deletedCount, 1)
        XCTAssertNotNil(summaryB.lastSharedAt)
    }

    private func insertVideo(
        context: NSManagedObjectContext,
        owner: String,
        status: RemoteVideoModel.Status,
        createdAt: Date
    ) throws {
        let entity = RemoteVideoEntity(context: context)
        entity.videoId = UUID().uuidString
        entity.ownerChild = owner
        entity.title = "Shared"
        entity.duration = 12
        entity.createdAt = createdAt
        entity.blobURL = "https://cdn.example.com/blob/\(UUID().uuidString)"
        entity.thumbURL = "https://cdn.example.com/thumb/\(UUID().uuidString)"
        entity.visibility = "followers"
        entity.status = status.rawValue
        entity.metadataJSON = "{}"
        entity.lastSyncedAt = createdAt
        try context.save()
    }
}
