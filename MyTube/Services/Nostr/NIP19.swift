//
//  NIP19.swift
//  MyTube
//
//  Created by Codex on 11/06/25.
//

import Foundation
import NostrSDK

enum NIP19Error {
    case unsupportedType
    case invalidDataLength
    case invalidEncoding
}

extension NIP19Error: Swift.Error {}

enum NIP19Kind: String {
    case npub
    case nsec
}

struct NIP19 {
    static func encodePublicKey(_ data: Data) throws -> String {
        try encode(data: data, kind: .npub)
    }

    static func encodePrivateKey(_ data: Data) throws -> String {
        try encode(data: data, kind: .nsec)
    }

    static func decode(_ value: String) throws -> (kind: NIP19Kind, data: Data) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw NIP19Error.invalidEncoding }

        if let publicKey = try? NostrSDK.PublicKey.parse(publicKey: normalized) {
            guard let data = Data(hexString: publicKey.toHex()) else {
                throw NIP19Error.invalidEncoding
            }
            return (.npub, data)
        }

        if let secretKey = try? NostrSDK.SecretKey.parse(secretKey: normalized) {
            guard let data = Data(hexString: secretKey.toHex()) else {
                throw NIP19Error.invalidEncoding
            }
            return (.nsec, data)
        }

        throw NIP19Error.invalidEncoding
    }

    private static func encode(data: Data, kind: NIP19Kind) throws -> String {
        guard data.count == 32 else {
            throw NIP19Error.invalidDataLength
        }

        switch kind {
        case .npub:
            let publicKey = try NostrSDK.PublicKey.fromBytes(bytes: data)
            return try publicKey.toBech32()
        case .nsec:
            let secretKey = try NostrSDK.SecretKey.fromBytes(bytes: data)
            return try secretKey.toBech32()
        }
    }
}
