//
//  ParentAuth.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation
import LocalAuthentication
import Security

enum ParentAuthError: Error {
    case pinNotConfigured
    case keychainFailure(OSStatus)
    case biometricUnavailable
    case invalidPIN
}

final class ParentAuth {
    private let service = "com.mytube.parentpin"
    private let account = "ParentPIN"

    func isPinConfigured() -> Bool {
        (try? readPIN()) != nil
    }

    func configure(pin: String) throws {
        let data = Data(pin.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]

        let status: OSStatus
        if isPinConfigured() {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw ParentAuthError.keychainFailure(status)
        }
    }

    func validate(pin: String) throws -> Bool {
        guard let stored = try readPIN() else {
            throw ParentAuthError.pinNotConfigured
        }
        return secureCompare(stored, with: pin)
    }

    func clearPin() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ParentAuthError.keychainFailure(status)
        }
    }

    func evaluateBiometric(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw ParentAuthError.biometricUnavailable
        }

        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    }

    private func readPIN() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ParentAuthError.keychainFailure(status)
        }
        guard let data = result as? Data, let pin = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pin
    }

    private func secureCompare(_ lhs: String, with rhs: String) -> Bool {
        let lhsData = Data(lhs.utf8)
        let rhsData = Data(rhs.utf8)
        guard lhsData.count == rhsData.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<lhsData.count {
            difference |= lhsData[i] ^ rhsData[i]
        }
        return difference == 0
    }
}
