//
//  StorageConfigurationStore.swift
//  MyTube
//
//  Created by Codex on 01/07/26.
//

import Foundation
import Security

enum StorageModeSelection: String, Codable {
    case managed
    case byo
}

struct UserStorageConfig: Codable, Sendable, Equatable {
    var endpoint: URL
    var bucket: String
    var region: String
    var accessKey: String
    var secretKey: String
    var pathStyle: Bool
}

final class StorageConfigurationStore {
    private enum Keys {
        static let mode = "com.mytube.storage.mode"
    }

    private let userDefaults: UserDefaults
    private let keychainService = "com.mytube.storage"
    private let keychainAccount = "byo.config"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func currentMode() -> StorageModeSelection {
        if let raw = userDefaults.string(forKey: Keys.mode),
           let mode = StorageModeSelection(rawValue: raw) {
            return mode
        }
        return .managed
    }

    func setMode(_ mode: StorageModeSelection) {
        userDefaults.set(mode.rawValue, forKey: Keys.mode)
    }

    func saveBYOConfig(_ config: UserStorageConfig) throws {
        let data = try JSONEncoder().encode(config)
        try writeToKeychain(data: data)
    }

    func loadBYOConfig() throws -> UserStorageConfig? {
        guard let data = try readFromKeychain() else { return nil }
        return try JSONDecoder().decode(UserStorageConfig.self, from: data)
    }

    func clearBYOConfig() throws {
        try deleteFromKeychain()
    }

    // MARK: - Keychain helpers

    private func writeToKeychain(data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainKeyStoreError.keychainFailure(status)
        }
    }

    private func readFromKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
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
        return result as? Data
    }

    private func deleteFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainKeyStoreError.keychainFailure(status)
        }
    }
}
