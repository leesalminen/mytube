//
//  KeychainKeyStore.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import Foundation
import NostrSDK
#if canImport(CryptoKit)
import CryptoKit
#endif

enum KeychainKeyStoreError: Error {
    case keyNotFound
    case dataCorrupted
    case keyGenerationFailed
    case keychainFailure(OSStatus)
}

private enum KeychainAccount {
    static let parentWrap = "parent.wrap.x25519"
}

enum NostrIdentityRole: Hashable, Sendable {
    case parent
    case child(id: UUID)

    var accountKey: String {
        switch self {
        case .parent:
            return "parent.signing"
        case .child(let id):
            return "child.signing.\(id.uuidString)"
        }
    }
}

struct NostrKeyPair: Sendable {
    private let secretKeyHex: String
    private let publicKeyHexValue: String
    let createdAt: Date

    init(secretKey: NostrSDK.SecretKey, createdAt: Date = Date()) throws {
        let keys = NostrSDK.Keys(secretKey: secretKey)
        self.secretKeyHex = secretKey.toHex()
        self.publicKeyHexValue = keys.publicKey().toHex()
        self.createdAt = createdAt
    }

    init(secretKeyHex: String, createdAt: Date = Date()) throws {
        let parsed = try NostrSDK.SecretKey.parse(secretKey: secretKeyHex)
        try self.init(secretKey: parsed, createdAt: createdAt)
    }

    init(privateKeyData: Data, createdAt: Date = Date()) throws {
        guard privateKeyData.count == 32 else {
            throw KeychainKeyStoreError.dataCorrupted
        }
        let secretKey = try NostrSDK.SecretKey.fromBytes(bytes: privateKeyData)
        try self.init(secretKey: secretKey, createdAt: createdAt)
    }

    var privateKeyData: Data {
        guard let data = Data(hexString: secretKeyHex) else {
            preconditionFailure("Invalid secret key hex")
        }
        return data
    }

    var publicKeyData: Data {
        guard let data = Data(hexString: publicKeyHexValue) else {
            preconditionFailure("Invalid public key hex")
        }
        return data
    }

    var publicKeyHex: String { publicKeyHexValue }

    var publicKeyBech32: String? {
        guard let key = try? NostrSDK.PublicKey.parse(publicKey: publicKeyHexValue) else { return nil }
        return try? key.toBech32()
    }

    var secretKeyBech32: String? {
        guard let key = try? NostrSDK.SecretKey.parse(secretKey: secretKeyHex) else { return nil }
        return try? key.toBech32()
    }

    func makeKeys() throws -> NostrSDK.Keys {
        let secretKey = try NostrSDK.SecretKey.parse(secretKey: secretKeyHex)
        return NostrSDK.Keys(secretKey: secretKey)
    }

    func secretKey() throws -> NostrSDK.SecretKey {
        try NostrSDK.SecretKey.parse(secretKey: secretKeyHex)
    }

    func publicKey() throws -> NostrSDK.PublicKey {
        try NostrSDK.PublicKey.parse(publicKey: publicKeyHexValue)
    }

    func exportSecretKeyHex() -> String {
        secretKeyHex
    }
}

struct ParentWrapKeyPair: Sendable {
    let privateKeyData: Data
    let createdAt: Date

    #if canImport(CryptoKit)
    func makePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
    }

    func publicKeyData() throws -> Data {
        try makePrivateKey().publicKey.rawRepresentation
    }

    func publicKeyBase64() throws -> String {
        try publicKeyData().base64EncodedString()
    }
    #else
    func makePrivateKey() throws -> Any {
        throw KeychainKeyStoreError.keyGenerationFailed
    }

    func publicKeyData() throws -> Data {
        throw KeychainKeyStoreError.keyGenerationFailed
    }

    func publicKeyBase64() throws -> String {
        throw KeychainKeyStoreError.keyGenerationFailed
    }
    #endif
}

/// Handles secure storage and retrieval of Nostr keypairs using the system keychain.
/// Parent keys target Secure Enclave via access control flags when available; child keys fall back to
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
final class KeychainKeyStore {
    private let service: String
    private let accessQueue = DispatchQueue(label: "com.mytube.keys.access", qos: .userInitiated)

    init(service: String = "com.mytube.keys") {
        self.service = service
    }

    func fetchKeyPair(role: NostrIdentityRole) throws -> NostrKeyPair? {
        try accessQueue.sync {
            try readKeyPair(account: role.accountKey)
        }
    }

    func ensureParentKeyPair() throws -> NostrKeyPair {
        if let existing = try fetchKeyPair(role: .parent) {
            return existing
        }
        let secret = NostrSDK.SecretKey.generate()
        let pair = try NostrKeyPair(secretKey: secret)
        try storeKeyPair(pair, role: .parent, requireBiometrics: false)
        return pair
    }

    func fetchParentWrapKeyPair() throws -> ParentWrapKeyPair? {
        try accessQueue.sync {
            try readWrapKeyPair()
        }
    }

    @discardableResult
    func ensureParentWrapKeyPair(requireBiometrics: Bool = false) throws -> ParentWrapKeyPair {
        if let existing = try fetchParentWrapKeyPair() {
            return existing
        }
#if canImport(CryptoKit)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let pair = ParentWrapKeyPair(privateKeyData: privateKey.rawRepresentation, createdAt: Date())
        try storeParentWrapKeyPair(pair, requireBiometrics: requireBiometrics)
        return pair
#else
        throw KeychainKeyStoreError.keyGenerationFailed
#endif
    }

    func storeKeyPair(_ pair: NostrKeyPair, role: NostrIdentityRole, requireBiometrics: Bool = false) throws {
        try accessQueue.sync {
            try writeKeyPair(pair, account: role.accountKey, requireBiometrics: requireBiometrics)
        }
    }

    func storeParentWrapKeyPair(_ pair: ParentWrapKeyPair, requireBiometrics: Bool = false) throws {
        try accessQueue.sync {
            try writeData(
                pair.privateKeyData,
                account: KeychainAccount.parentWrap,
                requireBiometrics: requireBiometrics
            )
        }
    }

    func removeKeyPair(role: NostrIdentityRole) throws {
        try accessQueue.sync {
            try deleteKeyPair(account: role.accountKey)
        }
    }

    func childKeyIdentifiers() throws -> [UUID] {
        try accessQueue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            guard status == errSecSuccess else {
                throw KeychainKeyStoreError.keychainFailure(status)
            }
            guard let items = result as? [[String: Any]] else { return [] }

            return items.compactMap { attributes -> UUID? in
                guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
                guard account.hasPrefix("child.signing.") else { return nil }
                let uuidString = account.replacingOccurrences(of: "child.signing.", with: "")
                return UUID(uuidString: uuidString)
            }
        }
    }

    func removeAll() throws {
        try accessQueue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]

            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainKeyStoreError.keychainFailure(status)
            }
        }
    }

    private func readKeyPair(account: String) throws -> NostrKeyPair? {
        guard let item = try readItem(account: account) else {
            return nil
        }
        return try NostrKeyPair(privateKeyData: item.data, createdAt: item.createdAt)
    }

    private func readWrapKeyPair() throws -> ParentWrapKeyPair? {
        guard let item = try readItem(account: KeychainAccount.parentWrap) else {
            return nil
        }
        return ParentWrapKeyPair(privateKeyData: item.data, createdAt: item.createdAt)
    }

    private func readItem(account: String) throws -> (data: Data, createdAt: Date)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainKeyStoreError.keychainFailure(status)
        }
        guard
            let item = result as? [String: Any],
            let data = item[kSecValueData as String] as? Data
        else {
            throw KeychainKeyStoreError.dataCorrupted
        }
        let createdAt: Date
        if let timestamp = item[kSecAttrCreationDate as String] as? Date {
            createdAt = timestamp
        } else {
            createdAt = Date()
        }

        return (data, createdAt)
    }

    private func writeKeyPair(
        _ pair: NostrKeyPair,
        account: String,
        requireBiometrics: Bool
    ) throws {
        try writeData(pair.privateKeyData, account: account, requireBiometrics: requireBiometrics)
    }

    private func writeData(
        _ data: Data,
        account: String,
        requireBiometrics: Bool
    ) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        if requireBiometrics {
            var error: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.userPresence],
                &error
            ) {
                addAttributes[kSecAttrAccessControl as String] = access
                addAttributes.removeValue(forKey: kSecAttrAccessible as String)
            } else if let err = error?.takeRetainedValue() {
                throw err
            }
        }

        var status = SecItemAdd(addAttributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemDelete(baseQuery as CFDictionary)
            status = SecItemAdd(addAttributes as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainKeyStoreError.keychainFailure(status)
        }
    }

    private func deleteKeyPair(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainKeyStoreError.keychainFailure(status)
        }
    }
}

extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
