//
//  ReportModels.swift
//  MyTube
//
//  Created by Assistant on 02/15/26.
//

import CoreData
import Foundation

enum ReportReason: String, CaseIterable, Codable, Sendable {
    case harassment
    case spam
    case inappropriate
    case illegal
    case other

    var displayName: String {
        switch self {
        case .harassment:
            return "Harassment or bullying"
        case .spam:
            return "Spam or scams"
        case .inappropriate:
            return "Inappropriate for kids"
        case .illegal:
            return "Illegal or dangerous"
        case .other:
            return "Other"
        }
    }
}

enum ReportStatus: String, Codable, Sendable {
    case pending
    case acknowledged
    case dismissed
    case actioned
}

enum ReportAction: String, Codable, Sendable {
    case none
    case reportOnly
    case unfollow
    case block
    case deleted
}

struct ReportModel: Identifiable, Hashable, Sendable {
    let id: UUID
    let videoId: String
    let subjectChild: String
    let reporterKey: String
    let reason: ReportReason
    let note: String?
    let createdAt: Date
    let status: ReportStatus
    let actionTaken: ReportAction?
    let lastActionAt: Date?
    let isOutbound: Bool
    let deliveredAt: Date?

    init(
        id: UUID,
        videoId: String,
        subjectChild: String,
        reporterKey: String,
        reason: ReportReason,
        note: String?,
        createdAt: Date,
        status: ReportStatus,
        actionTaken: ReportAction?,
        lastActionAt: Date?,
        isOutbound: Bool,
        deliveredAt: Date?
    ) {
        self.id = id
        self.videoId = videoId
        self.subjectChild = subjectChild
        self.reporterKey = reporterKey
        self.reason = reason
        self.note = note
        self.createdAt = createdAt
        self.status = status
        self.actionTaken = actionTaken
        self.lastActionAt = lastActionAt
        self.isOutbound = isOutbound
        self.deliveredAt = deliveredAt
    }

    init?(entity: ReportEntity) {
        guard
            let id = entity.id,
            let videoId = entity.videoId,
            let subjectChild = entity.subjectChild,
            let reporterKey = entity.reporterKey,
            let reasonRaw = entity.reason,
            let createdAt = entity.createdAt,
            let statusRaw = entity.status
        else {
            return nil
        }

        guard let reason = ReportReason(rawValue: reasonRaw) else {
            return nil
        }
        let status = ReportStatus(rawValue: statusRaw) ?? .pending
        let actionTaken = entity.actionTaken.flatMap { ReportAction(rawValue: $0) }

        self.init(
            id: id,
            videoId: videoId,
            subjectChild: subjectChild,
            reporterKey: reporterKey,
            reason: reason,
            note: entity.note,
            createdAt: createdAt,
            status: status,
            actionTaken: actionTaken,
            lastActionAt: entity.lastActionAt,
            isOutbound: entity.isOutbound,
            deliveredAt: entity.deliveredAt
        )
    }

    var isResolved: Bool {
        status == .dismissed || status == .actioned
    }
}
