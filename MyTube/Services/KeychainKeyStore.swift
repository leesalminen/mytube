//
//  KeychainKeyStore.swift
//  MyTube
//
//  Created by Codex on 10/28/25.
//

import CryptoKit
import Foundation

enum KeychainKeyStoreError: Error {
    case keyNotFound
    case dataCorrupted
    case keychainFailure(OSStatus)
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
    let privateKeyData: Data
    let publicKeyData: Data
    let createdAt: Date

    init(privateKey: Curve25519.Signing.PrivateKey, createdAt: Date = Date()) {
        self.privateKeyData = privateKey.rawRepresentation
        self.publicKeyData = privateKey.publicKey.rawRepresentation
        self.createdAt = createdAt
    }

    init(privateKeyData: Data, createdAt: Date = Date()) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        self.init(privateKey: key, createdAt: createdAt)
    }

    var publicKeyHex: String {
        publicKeyData.hexEncodedString()
    }
}

/// Handles secure storage and retrieval of Nostr keypairs using the system keychain.
/// Parent keys target Secure Enclave via access control flags when available; child keys fall back to
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
final class KeychainKeyStore {
    private let service = "com.mytube.keys"
    private let accessQueue = DispatchQueue(label: "com.mytube.keys.access", qos: .userInitiated)

    func fetchKeyPair(role: NostrIdentityRole) throws -> NostrKeyPair? {
        try accessQueue.sync {
            try readKeyPair(account: role.accountKey)
        }
    }

    func ensureParentKeyPair() throws -> NostrKeyPair {
        if let existing = try fetchKeyPair(role: .parent) {
            return existing
        }
        let key = Curve25519.Signing.PrivateKey()
        let pair = NostrKeyPair(privateKey: key)
        try storeKeyPair(pair, role: .parent, requireBiometrics: true)
        return pair
    }

    func storeKeyPair(_ pair: NostrKeyPair, role: NostrIdentityRole, requireBiometrics: Bool = false) throws {
        try accessQueue.sync {
            try writeKeyPair(pair, account: role.accountKey, requireBiometrics: requireBiometrics)
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

    private func readKeyPair(account: String) throws -> NostrKeyPair? {
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

        return try NostrKeyPair(privateKeyData: data, createdAt: createdAt)
    }

    private func writeKeyPair(
        _ pair: NostrKeyPair,
        account: String,
        requireBiometrics: Bool
    ) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: pair.privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]

        if requireBiometrics {
            var error: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                [.biometryCurrentSet],
                &error
            ) {
                attributes[kSecAttrAccessControl as String] = access
                attributes.removeValue(forKey: kSecAttrAccessible as String)
            } else if let err = error?.takeRetainedValue() {
                throw err
            }
        }

        let status: OSStatus
        if try readKeyPair(account: account) != nil {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            status = SecItemAdd(attributes as CFDictionary, nil)
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

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}

