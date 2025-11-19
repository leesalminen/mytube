//
//  IdentityManager.swift
//  MyTube
//
//  Created by Codex on 11/06/25.
//

import Foundation
import NostrSDK

enum IdentityManagerError: Error {
    case parentIdentityAlreadyExists
    case parentIdentityMissing
    case invalidPrivateKey
    case invalidPublicKey
    case profileNotFound
    case invalidProfileName
}

struct ParentIdentity {
    let keyPair: NostrKeyPair
    let wrapKeyPair: ParentWrapKeyPair?

    var publicKeyHex: String { keyPair.publicKeyHex }
    var publicKeyBech32: String? { keyPair.publicKeyBech32 }
    var secretKeyBech32: String? { keyPair.secretKeyBech32 }

    var wrapPublicKeyBase64: String? {
        guard let wrapKeyPair else { return nil }
        return try? wrapKeyPair.publicKeyBase64()
    }
}

struct ChildIdentity {
    let profile: ProfileModel
    var delegation: ChildDelegation?  // Deprecated
    
    // Children no longer have separate Nostr keys - they are just profiles owned by parents
    // All content is published under the parent's key with child metadata
    
    // Temporary compatibility: return profile ID as identifier
    var publicKeyHex: String {
        profile.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
    
    var publicKeyBech32: String? {
        nil  // Children don't have bech32 keys
    }
    
    var secretKeyBech32: String? {
        nil  // Children don't have secret keys
    }
    
    // Stub keyPair for compatibility - DO NOT USE for signing
    var keyPair: NostrKeyPair {
        // Create a deterministic but fake key from profile ID
        // This should NEVER be used for actual signing
        let profileBytes = profile.id.uuid
        let keyData = Data([
            profileBytes.0, profileBytes.1, profileBytes.2, profileBytes.3,
            profileBytes.4, profileBytes.5, profileBytes.6, profileBytes.7,
            profileBytes.8, profileBytes.9, profileBytes.10, profileBytes.11,
            profileBytes.12, profileBytes.13, profileBytes.14, profileBytes.15,
            profileBytes.0, profileBytes.1, profileBytes.2, profileBytes.3,
            profileBytes.4, profileBytes.5, profileBytes.6, profileBytes.7,
            profileBytes.8, profileBytes.9, profileBytes.10, profileBytes.11,
            profileBytes.12, profileBytes.13, profileBytes.14, profileBytes.15
        ])
        return try! NostrKeyPair(privateKeyData: keyData)
    }
}

// Delegation logic removed - children don't have separate keys anymore
// Stub types for compatibility
struct DelegationConditions: Equatable, Sendable {
    // Deprecated
    static func defaultChild(now: Date = Date(), duration: TimeInterval = 60 * 60 * 24 * 365) -> DelegationConditions {
        return DelegationConditions()
    }
    
    func encode() -> String {
        return ""  // Deprecated
    }
}

struct ChildDelegation: Sendable {
    // Deprecated - children don't have delegations anymore
    var delegatorPublicKey: String { "" }
    var delegateePublicKey: String { "" }
    var conditions: DelegationConditions { DelegationConditions() }
    var signature: String { "" }
    var nostrTag: Tag {
        NostrTagBuilder.make(name: "delegation", value: "", otherParameters: [])
    }
}

/// Coordinates key generation, import, and export for parent/child identities.
final class IdentityManager {
    private let keyStore: KeychainKeyStore
    private let profileStore: ProfileStore

    init(keyStore: KeychainKeyStore, profileStore: ProfileStore) {
        self.keyStore = keyStore
        self.profileStore = profileStore
    }

    func hasParentIdentity() -> Bool {
        (try? keyStore.fetchKeyPair(role: .parent)) != nil
    }

    func parentIdentity() throws -> ParentIdentity? {
        guard let pair = try keyStore.fetchKeyPair(role: .parent) else {
            return nil
        }
        let wrapPair = try keyStore.fetchParentWrapKeyPair() ?? keyStore.ensureParentWrapKeyPair(requireBiometrics: false)
        return ParentIdentity(keyPair: pair, wrapKeyPair: wrapPair)
    }

    @discardableResult
    func generateParentIdentity(requireBiometrics: Bool) throws -> ParentIdentity {
        guard try keyStore.fetchKeyPair(role: .parent) == nil else {
            throw IdentityManagerError.parentIdentityAlreadyExists
        }
        let secret = NostrSDK.SecretKey.generate()
        let pair = try NostrKeyPair(secretKey: secret)
        try keyStore.storeKeyPair(pair, role: .parent, requireBiometrics: requireBiometrics)
        let wrapPair = try keyStore.ensureParentWrapKeyPair(requireBiometrics: requireBiometrics)
        return ParentIdentity(keyPair: pair, wrapKeyPair: wrapPair)
    }

    @discardableResult
    func importParentIdentity(_ input: String, requireBiometrics: Bool) throws -> ParentIdentity {
        guard try keyStore.fetchKeyPair(role: .parent) == nil else {
            throw IdentityManagerError.parentIdentityAlreadyExists
        }
        let data = try decodePrivateKey(input)
        let pair = try NostrKeyPair(privateKeyData: data)
        try keyStore.storeKeyPair(pair, role: .parent, requireBiometrics: requireBiometrics)
        let wrapPair = try keyStore.ensureParentWrapKeyPair(requireBiometrics: requireBiometrics)
        return ParentIdentity(keyPair: pair, wrapKeyPair: wrapPair)
    }

    func parentWrapKeyPair(requireBiometrics: Bool = false) throws -> ParentWrapKeyPair {
        if let existing = try keyStore.fetchParentWrapKeyPair() {
            return existing
        }
        return try keyStore.ensureParentWrapKeyPair(requireBiometrics: requireBiometrics)
    }

    func createChildIdentity(
        name: String,
        theme: ThemeDescriptor,
        avatarAsset: String
    ) throws -> ChildIdentity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IdentityManagerError.invalidProfileName
        }

        guard try keyStore.fetchKeyPair(role: .parent) != nil else {
            throw IdentityManagerError.parentIdentityMissing
        }

        let profile = try profileStore.createProfile(
            name: trimmed,
            theme: theme,
            avatarAsset: avatarAsset
        )
        
        return ChildIdentity(profile: profile)
    }

    func childIdentity(for profile: ProfileModel) -> ChildIdentity? {
        // Always return the identity since children are just profiles now
        return ChildIdentity(profile: profile)
    }

    func allChildIdentities() throws -> [ChildIdentity] {
        let profiles = try profileStore.fetchProfiles()
        return profiles.map { ChildIdentity(profile: $0) }
    }

    // Deprecated stub methods for compatibility
    func ensureChildIdentity(for profile: ProfileModel) throws -> ChildIdentity {
        return ChildIdentity(profile: profile)
    }
    
    func importChildIdentity(_ secret: String, profileName: String, theme: ThemeDescriptor, avatarAsset: String) throws -> ChildIdentity {
        // Deprecated - just create a profile
        return try createChildIdentity(name: profileName, theme: theme, avatarAsset: avatarAsset)
    }
    
    func issueDelegation(to child: ChildIdentity, conditions: DelegationConditions) throws -> ChildDelegation {
        // Deprecated - return empty delegation
        return ChildDelegation()
    }

    private func decodePrivateKey(_ string: String) throws -> Data {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw IdentityManagerError.invalidPrivateKey }

        let lower = cleaned.lowercased()
        if let data = Data(hexString: lower), data.count == 32 {
            return data
        }
        if lower.hasPrefix(NIP19Kind.nsec.rawValue) {
            let decoded = try NIP19.decode(lower)
            guard decoded.kind == .nsec else {
                throw IdentityManagerError.invalidPrivateKey
            }
            return decoded.data
        }
        throw IdentityManagerError.invalidPrivateKey
    }
}
