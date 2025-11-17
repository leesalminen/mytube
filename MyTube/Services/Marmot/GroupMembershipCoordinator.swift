//
//  GroupMembershipCoordinator.swift
//  MyTube
//
//  Created by Codex on 02/17/26.
//

import Foundation
import MDKBindings
import OSLog

protocol GroupMembershipCoordinating: Actor {
    func createGroup(request: GroupMembershipCoordinator.CreateGroupRequest) async throws -> GroupMembershipCoordinator.CreateGroupResponse
    func addMembers(request: GroupMembershipCoordinator.AddMembersRequest) async throws -> GroupMembershipCoordinator.AddMembersResponse
    func removeMembers(request: GroupMembershipCoordinator.RemoveMembersRequest) async throws -> GroupMembershipCoordinator.RemoveMembersResponse
}

protocol MarmotPublishingTransport: AnyObject {
    func publish(
        createGroupResult result: CreateGroupResult,
        keyPackageEventsJson: [String],
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.CreateGroupPublishResult

    func publish(
        addMembersResult result: AddMembersResult,
        keyPackageEventsJson: [String],
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.MemberUpdatePublishResult

    func publish(
        removeMembersResult result: GroupUpdateResult,
        relayOverride: [URL]?
    ) async throws -> MarmotTransport.MemberRemovalPublishResult
}

extension MarmotTransport: MarmotPublishingTransport { }

actor GroupMembershipCoordinator {
    struct CreateGroupRequest {
        let creatorPublicKeyHex: String
        let memberKeyPackageEventsJson: [String]
        let name: String
        let description: String
        let relays: [String]
        let adminPublicKeys: [String]
        let relayOverride: [URL]?
    }

    struct CreateGroupResponse {
        let result: CreateGroupResult
        let publishResult: MarmotTransport.CreateGroupPublishResult
    }

    struct AddMembersRequest {
        let mlsGroupId: String
        let keyPackageEventsJson: [String]
        let relayOverride: [URL]?
    }

    struct AddMembersResponse {
        let result: AddMembersResult
        let publishResult: MarmotTransport.MemberUpdatePublishResult
    }

    struct RemoveMembersRequest {
        let mlsGroupId: String
        let memberPublicKeys: [String]
        let relayOverride: [URL]?
    }

    struct RemoveMembersResponse {
        let result: GroupUpdateResult
        let publishResult: MarmotTransport.MemberRemovalPublishResult
    }

    private let mdkActor: any MarmotMdkClient
    private let marmotTransport: MarmotPublishingTransport
    private let logger = Logger(subsystem: "com.mytube", category: "GroupMembershipCoordinator")

    init(
        mdkActor: any MarmotMdkClient,
        marmotTransport: MarmotPublishingTransport
    ) {
        self.mdkActor = mdkActor
        self.marmotTransport = marmotTransport
    }

    func createGroup(request: CreateGroupRequest) async throws -> CreateGroupResponse {
        let result = try await mdkActor.createGroup(
            creatorPublicKey: request.creatorPublicKeyHex,
            memberKeyPackageEventsJson: request.memberKeyPackageEventsJson,
            name: request.name,
            description: request.description,
            relays: request.relays,
            admins: request.adminPublicKeys
        )
        let publishResult = try await marmotTransport.publish(
            createGroupResult: result,
            keyPackageEventsJson: request.memberKeyPackageEventsJson,
            relayOverride: request.relayOverride
        )
        logger.debug("Created MDK group \(result.group.mlsGroupId, privacy: .public) and published \(publishResult.welcomeGiftWraps.count) gift wraps.")
        NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
        return CreateGroupResponse(result: result, publishResult: publishResult)
    }

    func addMembers(request: AddMembersRequest) async throws -> AddMembersResponse {
        let result = try await mdkActor.addMembers(
            mlsGroupId: request.mlsGroupId,
            keyPackageEventsJson: request.keyPackageEventsJson
        )
        let publishResult = try await marmotTransport.publish(
            addMembersResult: result,
            keyPackageEventsJson: request.keyPackageEventsJson,
            relayOverride: request.relayOverride
        )
        logger.debug("Added members to group \(request.mlsGroupId, privacy: .public); published \(publishResult.welcomeGiftWraps.count) gift wraps.")
        NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
        return AddMembersResponse(result: result, publishResult: publishResult)
    }

    func removeMembers(request: RemoveMembersRequest) async throws -> RemoveMembersResponse {
        let result = try await mdkActor.removeMembers(
            mlsGroupId: request.mlsGroupId,
            memberPublicKeys: request.memberPublicKeys
        )
        let publishResult = try await marmotTransport.publish(
            removeMembersResult: result,
            relayOverride: request.relayOverride
        )
        logger.debug("Removed members from group \(request.mlsGroupId, privacy: .public); published commit \(publishResult.evolutionEvent.idHex, privacy: .public).")
        NotificationCenter.default.post(name: .marmotStateDidChange, object: nil)
        return RemoveMembersResponse(result: result, publishResult: publishResult)
    }
}

extension GroupMembershipCoordinator: GroupMembershipCoordinating { }
