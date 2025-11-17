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
    let keyPair: NostrKeyPair
    var delegation: ChildDelegation?

    var publicKeyHex: String { keyPair.publicKeyHex }
    var publicKeyBech32: String? { keyPair.publicKeyBech32 }
    var secretKeyBech32: String? { keyPair.secretKeyBech32 }
}

struct DelegationConditions: Equatable, Sendable {
    var kinds: [Int]
    var since: Date
    var until: Date

    var sinceUnix: Int { Int(since.timeIntervalSince1970) }
    var untilUnix: Int { Int(until.timeIntervalSince1970) }

    func encode() -> String {
        var parts: [String] = []
        for kind in kinds.sorted() {
            parts.append("kind=\(kind)")
        }
        parts.append("since=\(sinceUnix)")
        parts.append("until=\(untilUnix)")
        return parts.joined(separator: "&")
    }

    static func defaultChild(now: Date = Date(), duration: TimeInterval = 60 * 60 * 24 * 365) -> DelegationConditions {
        let since = now.addingTimeInterval(-60 * 60 * 24)
        let until = now.addingTimeInterval(duration)
        return DelegationConditions(
            kinds: ChildDelegationDefaults.allowedKinds,
            since: since,
            until: until
        )
    }
}

struct ChildDelegation: Sendable {
    let delegatorPublicKey: String
    let delegateePublicKey: String
    let conditions: DelegationConditions
    let signature: String

    var nostrTag: Tag {
        NostrTagBuilder.make(name: "delegation", value: delegateePublicKey, otherParameters: [conditions.encode(), signature])
    }

    var exportDictionary: [String: Any] {
        [
            "delegator": delegatorPublicKey,
            "delegatee": delegateePublicKey,
            "conditions": conditions.encode(),
            "signature": signature
        ]
    }
}

enum ChildDelegationDefaults {
    static let allowedKinds: [Int] = [
        MyTubeEventKind.childFollowPointer.rawValue
    ]
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

    @discardableResult
    func ensureChildIdentity(for profile: ProfileModel) throws -> ChildIdentity {
        if let existing = try keyStore.fetchKeyPair(role: .child(id: profile.id)) {
            return ChildIdentity(profile: profile, keyPair: existing)
        }
        let secret = NostrSDK.SecretKey.generate()
        let pair = try NostrKeyPair(secretKey: secret)
        try keyStore.storeKeyPair(pair, role: .child(id: profile.id))
        return ChildIdentity(profile: profile, keyPair: pair)
    }

    @discardableResult
    func createChildIdentity(
        name: String,
        theme: ThemeDescriptor,
        avatarAsset: String,
        shouldIssueDelegation: Bool = true,
        now: Date = Date()
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
        var identity = try ensureChildIdentity(for: profile)

        if shouldIssueDelegation {
            let conditions = DelegationConditions.defaultChild(now: now)
            let delegation = try issueDelegation(to: identity, conditions: conditions)
            identity.delegation = delegation
        }

        return identity
    }

    func childIdentity(for profile: ProfileModel) throws -> ChildIdentity? {
        guard let pair = try keyStore.fetchKeyPair(role: .child(id: profile.id)) else {
            return nil
        }
        return ChildIdentity(profile: profile, keyPair: pair)
    }

    func allChildIdentities() throws -> [ChildIdentity] {
        let profiles = try profileStore.fetchProfiles()
        return try profiles.compactMap { profile in
            let pair = try keyStore.fetchKeyPair(role: .child(id: profile.id))
            if let pair {
                return ChildIdentity(profile: profile, keyPair: pair)
            }
            return nil
        }
    }

    @discardableResult
    func importChildIdentity(_ secret: String, for profile: ProfileModel) throws -> ChildIdentity {
        let data = try decodePrivateKey(secret)
        let pair = try NostrKeyPair(privateKeyData: data)
        try keyStore.storeKeyPair(pair, role: .child(id: profile.id))
        return ChildIdentity(profile: profile, keyPair: pair)
    }

    @discardableResult
    func importChildIdentity(
        _ secret: String,
        profileName: String,
        theme: ThemeDescriptor,
        avatarAsset: String
    ) throws -> ChildIdentity {
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IdentityManagerError.invalidProfileName
        }

        let profile = try profileStore.createProfile(
            name: trimmed,
            theme: theme,
            avatarAsset: avatarAsset
        )
        return try importChildIdentity(secret, for: profile)
    }

    func issueDelegation(
        to child: ChildIdentity,
        conditions: DelegationConditions,
        signer: NostrEventSigner = NostrEventSigner()
    ) throws -> ChildDelegation {
        guard let parentPair = try keyStore.fetchKeyPair(role: .parent) else {
            throw IdentityManagerError.parentIdentityMissing
        }

        let signature = try signer.signDelegation(
            delegatorKey: parentPair,
            delegateePublicKeyHex: child.publicKeyHex,
            conditions: conditions.encode()
        )

        return ChildDelegation(
            delegatorPublicKey: parentPair.publicKeyHex,
            delegateePublicKey: child.publicKeyHex,
            conditions: conditions,
            signature: signature
        )
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
