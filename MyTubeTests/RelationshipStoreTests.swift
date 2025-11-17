import XCTest
@testable import MyTube

final class RelationshipStoreTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: RelationshipStore!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        store = RelationshipStore(persistence: persistence)
    }

    override func tearDown() {
        store = nil
        persistence = nil
        super.tearDown()
    }

    func testUpsertFollowCreatesAndUpdatesRecord() throws {
        let follower = String(repeating: "a", count: 64)
        let target = String(repeating: "b", count: 64)
        let parentKey = String(repeating: "c", count: 64)
        let initialDate = Date()

        let initialMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: parentKey,
            timestamp: initialDate
        )

        let created = try store.upsertFollow(message: initialMessage, updatedAt: initialDate)
        XCTAssertEqual(created.status, .pending)
        XCTAssertTrue(created.approvedFrom)
        XCTAssertFalse(created.approvedTo)
        XCTAssertEqual(created.followerChild, follower)
        XCTAssertEqual(created.targetChild, target)
        XCTAssertEqual(created.participantParentKeys, [parentKey.lowercased()])

        let followDate = initialDate.addingTimeInterval(60)
        let updatedMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: parentKey,
            timestamp: followDate
        )

        let updated = try store.upsertFollow(message: updatedMessage, updatedAt: followDate)
        XCTAssertEqual(updated.status, .active)
        XCTAssertTrue(updated.approvedFrom)
        XCTAssertTrue(updated.approvedTo)

        let fetched = try store.fetchFollowRelationships()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.status, .active)
        XCTAssertEqual(fetched.first?.approvedTo, true)
        XCTAssertEqual(fetched.first?.participantParentKeys, [parentKey.lowercased()])
    }

    func testUpsertFollowAddsParticipantKeys() throws {
        let follower = String(repeating: "a", count: 64)
        let target = String(repeating: "b", count: 64)
        let localParent = String(repeating: "c", count: 64)
        let remoteParent = String(repeating: "d", count: 64)
        let timestamp = Date()

        let message = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: localParent,
            timestamp: timestamp
        )

        let model = try store.upsertFollow(
            message: message,
            updatedAt: timestamp,
            participantKeys: [remoteParent]
        )

        XCTAssertEqual(
            Set(model.participantParentKeys),
            Set([localParent.lowercased(), remoteParent.lowercased()])
        )
    }

    func testUpsertFollowDoesNotDowngradeApprovalsWithoutRevocation() throws {
        let follower = String(repeating: "1", count: 64)
        let target = String(repeating: "2", count: 64)
        let localParent = String(repeating: "3", count: 64)
        let remoteParent = String(repeating: "4", count: 64)
        let initialDate = Date()

        let activeMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: localParent,
            timestamp: initialDate
        )

        let active = try store.upsertFollow(
            message: activeMessage,
            updatedAt: initialDate,
            participantKeys: [remoteParent]
        )
        XCTAssertTrue(active.approvedTo)
        XCTAssertEqual(active.status, .active)

        let laterDate = initialDate.addingTimeInterval(120)
        let remotePointerMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: false,
            status: FollowModel.Status.pending.rawValue,
            by: remoteParent,
            timestamp: laterDate
        )

        let updated = try store.upsertFollow(
            message: remotePointerMessage,
            updatedAt: laterDate,
            participantKeys: [remoteParent]
        )

        XCTAssertTrue(updated.approvedTo)
        XCTAssertTrue(updated.approvedFrom)
        XCTAssertEqual(updated.status, .active)
    }

    func testUpsertFollowResetsApprovalsOnRevocation() throws {
        let follower = String(repeating: "5", count: 64)
        let target = String(repeating: "6", count: 64)
        let localParent = String(repeating: "7", count: 64)
        let remoteParent = String(repeating: "8", count: 64)
        let initialDate = Date()

        let activeMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: localParent,
            timestamp: initialDate
        )

        _ = try store.upsertFollow(
            message: activeMessage,
            updatedAt: initialDate,
            participantKeys: [remoteParent]
        )

        let revocationDate = initialDate.addingTimeInterval(240)
        let revocationMessage = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: false,
            approvedTo: false,
            status: FollowModel.Status.revoked.rawValue,
            by: localParent,
            timestamp: revocationDate
        )

        let revoked = try store.upsertFollow(
            message: revocationMessage,
            updatedAt: revocationDate,
            participantKeys: [remoteParent]
        )

        XCTAssertFalse(revoked.approvedFrom)
        XCTAssertFalse(revoked.approvedTo)
        XCTAssertEqual(revoked.status, .revoked)
    }

    func testUpsertFollowPersistsMlsGroupId() throws {
        let follower = String(repeating: "a", count: 64)
        let target = String(repeating: "b", count: 64)
        let parentKey = String(repeating: "c", count: 64)
        let groupId = String(repeating: "d", count: 32)
        let message = FollowMessage(
            followerChild: follower,
            targetChild: target,
            approvedFrom: true,
            approvedTo: true,
            status: FollowModel.Status.active.rawValue,
            by: parentKey,
            timestamp: Date()
        )

        let updated = try store.upsertFollow(
            message: message,
            updatedAt: Date(),
            participantKeys: [parentKey],
            mlsGroupId: groupId
        )

        XCTAssertEqual(updated.mlsGroupId, groupId)
        let fetched = try store.fetchFollowRelationships()
        XCTAssertEqual(fetched.first?.mlsGroupId, groupId)
    }
}
