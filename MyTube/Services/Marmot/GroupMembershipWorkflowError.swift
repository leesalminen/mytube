//
//  GroupMembershipWorkflowError.swift
//  MyTube
//
//  Created by Codex on 02/18/26.
//

import Foundation

enum GroupMembershipWorkflowError: LocalizedError {
    case parentIdentityMissing
    case relaysUnavailable
    case keyPackageMissing
    case groupIdentifierMissing

    var errorDescription: String? {
        switch self {
        case .parentIdentityMissing:
            return "Generate or import a parent key before creating groups."
        case .relaysUnavailable:
            return "Configure at least one relay before creating Marmot groups."
        case .keyPackageMissing:
            return "Scan an invite that includes Marmot key packages before sending this request."
        case .groupIdentifierMissing:
            return "Set up the child's secure group before sending invites."
        }
    }
}
